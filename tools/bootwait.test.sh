#!/system/bin/sh
# v1.3.6 boot FUSE defer 回归（真实守护 + 假 tracefs + FIFO）
# 1) 开机宽限期内 fix 返回 defer=fuse → boot_wait，退避重试，不写 fix_error；
#    状态恢复 ok 后描述恢复。
# 2) 超过宽限期仍 defer → fuse_missing，只记一次日志，仍不写 fix_error。
# 用法：sh tools/bootwait.test.sh
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1
DAEMON=scripts/si-mount-eventd.sh
# 守护事件循环用 read -t（mksh 扩展），必须挑一个支持它的 shell。
# 解释器可移植：默认 Android 的 /system/bin/sh；不存在/不可执行时回退 mksh → sh。
# 守护事件循环用 read -t（mksh 扩展），必须挑一个支持它的 shell。
DSH=${SI_TEST_SHELL:-${SI_TEST_SH:-/system/bin/sh}}
if ! { command -v "$DSH" >/dev/null 2>&1 && "$DSH" -c ':' >/dev/null 2>&1; }; then
  DSH=$(command -v mksh 2>/dev/null)
fi
if [ -z "$DSH" ] || ! { command -v "$DSH" >/dev/null 2>&1 && "$DSH" -c ':' >/dev/null 2>&1; }; then
  DSH=$(command -v sh 2>/dev/null)
fi
if [ -z "$DSH" ] || ! { command -v "$DSH" >/dev/null 2>&1 && "$DSH" -c ':' >/dev/null 2>&1; }; then
  echo "找不到 mksh/sh（可用 SI_TEST_SH=... 指定）"; exit 1
fi
"$DSH" -c 'read -t 1 _probe' </dev/null >/dev/null 2>&1
case $? in
  0|1) ;;
  *) echo "需要支持 read -t 的 shell（mksh），当前 $DSH 不支持"; exit 1 ;;
esac

T=${TMPDIR:-/tmp}/si-bootwait-test.$$
DATA=$T/data; MOD=$T/mod; TRACE=$T/trace; I=$TRACE/instances/si_mount_fix
DPID=""; WP=""; SP=""
cleanup() {
  for _p in "$DPID" "$WP" "$SP"; do [ -n "$_p" ] && kill -9 "$_p" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT INT TERM HUP

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }
wait_status() {
  _i=0
  while [ "$_i" -lt 150 ]; do
    grep -q "$1" "$DATA/status.json" 2>/dev/null && return 0
    sleep 0.1; _i=$((_i + 1))
  done
  return 1
}
wait_prop() {
  _i=0
  while [ "$_i" -lt 50 ]; do
    grep -q "$1" "$MOD/module.prop" 2>/dev/null && return 0
    sleep 0.1; _i=$((_i + 1))
  done
  return 1
}
# 等 fix 调用次数超过基线（有上限），替代固定 sleep：慢机器多等，快机器立刻过。
wait_fix_runs() {   # $1=基线行数 $2=超时秒数
  _i=0; _max=$(( $2 * 10 ))
  while [ "$_i" -lt "$_max" ]; do
    _n=$(wc -l < "$T/fix.log" 2>/dev/null || echo 0)
    [ "$_n" -gt "$1" ] && return 0
    sleep 0.1; _i=$((_i + 1))
  done
  return 1
}

reset_fixture() {
  rm -rf "$DATA" "$MOD" "$TRACE" "$T/fix.state" "$T/fix.log"
  mkdir -p "$DATA" "$MOD/scripts" "$MOD/webroot" "$I/events/kprobes/si_fix_pu" \
           "$I/events/kprobes/si_fix_pm" "$TRACE/events/kprobes/si_fix_pu" \
           "$TRACE/events/kprobes/si_fix_pm" "$I/per_cpu/cpu0" || exit 1
  printf 'ENABLED=1\nMODE=auto\nPOLL_INTERVAL=60\nMIN_AGE=15\n' > "$DATA/config.conf"
  printf 'version=v1.3.6\nversionCode=136\ndescription=x\n' > "$MOD/module.prop"
  # stub 只决定“这轮输出什么数字”，RESULT 行格式来自真实 scripts/result.sh，
  # daemon 的 token 一旦变化，stub 会跟着变，不会出现测试仍绿的漂移。
  cat > "$MOD/scripts/fix-si-mounts.sh" <<'S'
#!/bin/sh
. "$(dirname "$0")/result.sh"
case "$1" in --trim-only) exit 0 ;; esac
echo run >> "$SI_TEST_FIX_LOG"
if [ -f "$SI_TEST_FIX_STATE" ] && [ "$(cat "$SI_TEST_FIX_STATE" 2>/dev/null)" = defer ]; then
  result_line 0 0 0 0 defer=fuse
else
  result_line 1 0 0 0
fi
S
  cp scripts/result.sh "$MOD/scripts/result.sh" || exit 1
  chmod 755 "$MOD/scripts/fix-si-mounts.sh" "$MOD/scripts/result.sh"
  printf 'p:si_fix_pu path_umount\np:si_fix_pm path_mount\n' > "$TRACE/kprobe_events"
  echo 1 > "$I/tracing_on"
  echo 1 > "$I/events/enable"
  echo 1 > "$I/events/kprobes/si_fix_pm/enable"
  echo 1 > "$I/events/kprobes/si_fix_pu/enable"
  echo 1 > "$TRACE/events/kprobes/si_fix_pm/enable"
  echo 1 > "$TRACE/events/kprobes/si_fix_pu/enable"
  printf '  si_fix_pu  0  0\n  si_fix_pm  0  0\n' > "$TRACE/kprobe_profile"
  printf 'entries: 0\noverrun: 0\nread events: 0\n' > "$I/per_cpu/cpu0/stats"
  mkfifo "$I/trace_pipe"
  sh -c 'exec 8> "$1"; exec sleep 120' _ "$I/trace_pipe" &
  WP=$!
}

start_daemon() {   # $1=uptime $2=grace $3=fuse retry
  SI_DATA=$DATA SI_MOD=$MOD SI_TRACE=$TRACE SI_TEST=1 \
    SI_UPTIME=$1 SI_FUSE_GRACE=$2 SI_FUSE_BACKOFF_MAX=1 SI_FUSE_RETRY=${3:-60} \
    SI_TEST_FIX_LOG=$T/fix.log SI_TEST_FIX_STATE=$T/fix.state \
    "$DSH" "$DAEMON" > "$T/daemon.out" 2>&1 &
  DPID=$!
}
stop_daemon() {
  [ -n "$DPID" ] || return 0
  kill "$DPID" 2>/dev/null
  _i=0
  while [ "$_i" -lt 50 ] && kill -0 "$DPID" 2>/dev/null; do sleep 0.1; _i=$((_i+1)); done
  kill -9 "$DPID" 2>/dev/null
  wait "$DPID" 2>/dev/null
  DPID=""
  kill -9 "$WP" 2>/dev/null; WP=""
}

# ---------- 1) 宽限期内：boot_wait，退避重试，恢复 ok ----------
reset_fixture
echo defer > "$T/fix.state"
start_daemon 1 5
if wait_status '"reason":"boot_wait"'; then
  ok "宽限期内 status=reason:boot_wait"
else
  bad "没有进入 boot_wait：$(cat "$DATA/status.json" 2>/dev/null)"
fi
case "$(cat "$DATA/status.json" 2>/dev/null)" in
  *fix_error*) bad "boot_wait 被写成 fix_error" ;;
  *) ok "boot_wait 不是 fix_error" ;;
esac
wait_prop '等待 FUSE 就绪' && ok "描述为“等待 FUSE 就绪”" \
  || bad "描述没有 boot_wait 文案：$(grep '^description=' "$MOD/module.prop" 2>/dev/null)"
_n1=$(wc -l < "$T/fix.log" 2>/dev/null || echo 0)
# 连续事件风暴：read 一直不超时，退避检查也不能被饿死
(
  i=0
  while [ "$i" -lt 30 ]; do
    printf 'si_fix_pm: storm\n' > "$I/trace_pipe" 2>/dev/null
    sleep 0.1
    i=$((i + 1))
  done
) &
SP=$!
if wait_fix_runs "$_n1" 8; then
  _n2=$(wc -l < "$T/fix.log" 2>/dev/null || echo 0)
  ok "连续事件下退避重试仍发生（run $_n1 -> $_n2）"
else
  _n2=$(wc -l < "$T/fix.log" 2>/dev/null || echo 0)
  bad "事件风暴饿死退避（run $_n1 -> $_n2）"
fi
kill -9 "$SP" 2>/dev/null; SP=""
echo ok > "$T/fix.state"
if wait_status '"reason":"ok"'; then
  ok "FUSE 就绪后恢复 reason:ok"
else
  bad "没有恢复 ok：$(cat "$DATA/status.json" 2>/dev/null)"
fi
wait_prop '事件驱动' && ok "描述恢复正常" || bad "描述没有恢复"
grep -q 'FUSE 层已就绪' "$DATA/daemon.log" 2>/dev/null \
  && ok "日志记录 FUSE 恢复" || bad "日志没有 FUSE 恢复"
case "$(cat "$DATA/status.json" 2>/dev/null)" in
  *fix_error*) bad "恢复后仍留 fix_error" ;;
  *) ok "全程没有 fix_error" ;;
esac
stop_daemon

# ---------- 2) 超过宽限期：fuse_missing，只记一次日志，仍不是 fix_error ----------
reset_fixture
echo defer > "$T/fix.state"
start_daemon 10 2 1
if wait_status '"reason":"fuse_missing"'; then
  ok "超宽限后 status=reason:fuse_missing"
else
  bad "没有进入 fuse_missing：$(cat "$DATA/status.json" 2>/dev/null)"
fi
case "$(cat "$DATA/status.json" 2>/dev/null)" in
  *fix_error*) bad "fuse_missing 被写成 fix_error" ;;
  *) ok "fuse_missing 不是 fix_error" ;;
esac
wait_prop 'FUSE 层未就绪' && ok "描述为“FUSE 层未就绪”" \
  || bad "描述没有 fuse_missing 文案"
_cnt=$(grep -c 'FUSE 层 10s 未就绪' "$DATA/daemon.log" 2>/dev/null || echo 0)
[ "$_cnt" -eq 1 ] && ok "FUSE 未就绪日志只记一次" || bad "日志次数=$_cnt（应 1）"
_n1=$(wc -l < "$T/fix.log" 2>/dev/null || echo 0)
if wait_fix_runs "$_n1" 8; then
  _n2=$(wc -l < "$T/fix.log" 2>/dev/null || echo 0)
  ok "fuse_missing 后仍有 60s 重试（run $_n1 -> $_n2；测试缩短为 1s）"
else
  _n2=$(wc -l < "$T/fix.log" 2>/dev/null || echo 0)
  bad "fuse_missing 后没有重试（run $_n1 -> $_n2）"
fi
stop_daemon

echo
[ "$fail" = 0 ] && { echo "bootwait.test: PASS"; exit 0; }
echo "bootwait.test: FAIL"; exit 1
