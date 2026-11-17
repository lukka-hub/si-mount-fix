#!/system/bin/sh
# 4.4 假活自检回归（真实守护脚本 + 假 tracefs + FIFO 事件通道）
#
# 覆盖：
#   1) kprobe 命中持续增长、实例 read events 不涨、last_event 很旧
#      → 连续 2 个采样周期后 status.blind=1 / reason=blind
#   2) 模块描述出现“事件通道异常，请重启手机”
#   3) 收到一条真事件 → blind=0 / reason=ok，描述恢复
#   4) 全程不删实例/kprobe、不改 tracing_on（保守分支）
#
# 用法：sh tools/blind.test.sh
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1
DAEMON=scripts/si-mount-eventd.sh
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

T=${TMPDIR:-/tmp}/si-blind-test.$$
DATA=$T/data; MOD=$T/mod; TRACE=$T/trace; I=$TRACE/instances/si_mount_fix
DPID=""; WP=""; UP=""
cleanup() {
  for _p in "$DPID" "$WP" "$UP"; do [ -n "$_p" ] && kill -9 "$_p" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT INT TERM HUP
mkdir -p "$DATA" "$MOD/scripts" "$MOD/webroot" "$I/events/kprobes/si_fix_pu" \
         "$I/events/kprobes/si_fix_pm" "$TRACE/events/kprobes/si_fix_pu" \
         "$TRACE/events/kprobes/si_fix_pm" "$I/per_cpu/cpu0" || exit 1
printf 'ENABLED=1\nMODE=auto\nPOLL_INTERVAL=60\nMIN_AGE=15\n' > "$DATA/config.conf"
printf 'version=v1.3.5\nversionCode=135\ndescription=x\n' > "$MOD/module.prop"
# RESULT 行格式来自真实 scripts/result.sh（fixture 复制到 scripts/ 下），
# 生产端 token 改了 stub 会跟着改，避免“stub 早已过期但测试仍绿”。
cat > "$MOD/scripts/fix-si-mounts.sh" <<'S'
#!/bin/sh
. "$(dirname "$0")/result.sh"
result_line 0 0 0 0
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
echo keep > "$I/keepme"
printf '  si_fix_pu  0  0\n  si_fix_pm  0  0\n' > "$TRACE/kprobe_profile"
cat > "$I/per_cpu/cpu0/stats" <<'M'
entries: 0
overrun: 0
read events: 0
M
mkfifo "$I/trace_pipe"
# 保持 FIFO 有写端，pipe_open_ok/exec 3< 才不会被阻塞
sh -c 'exec 8> "$1"; exec sleep 120' _ "$I/trace_pipe" &
WP=$!

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }
wait_status() {   # $1=grep 模式
  _i=0
  while [ "$_i" -lt 120 ]; do
    grep -q "$1" "$DATA/status.json" 2>/dev/null && return 0
    sleep 0.1; _i=$((_i + 1))
  done
  return 1
}
wait_prop() {     # $1=grep 模式
  _i=0
  while [ "$_i" -lt 50 ]; do
    grep -q "$1" "$MOD/module.prop" 2>/dev/null && return 0
    sleep 0.1; _i=$((_i + 1))
  done
  return 1
}
# 负例观察窗口：最多 $1 厘秒，每 0.1s 轮询一次；$2=要一直保持的 grep 模式。
# 出现反转立即返回 1（失败快），窗口到点仍成立返回 0。
hold_status() {
  _i=0; _max=$1; _pat=$2
  while [ "$_i" -lt "$_max" ]; do
    grep -q "$_pat" "$DATA/status.json" 2>/dev/null || return 1
    sleep 0.1; _i=$((_i + 1))
  done
  return 0
}

SI_DATA=$DATA SI_MOD=$MOD SI_TRACE=$TRACE SI_TEST=1 \
  SI_BLIND_EVERY=1 SI_BLIND_MIN_HITS=10 SI_BLIND_QUIET=2 \
  "$DSH" "$DAEMON" > "$T/daemon.out" 2>&1 &
DPID=$!

if wait_status '"mode":"event"'; then
  ok "守护进入 event 模式"
else
  bad "守护没有进入 event：$(cat "$DATA/status.json" 2>/dev/null)"
  exit 1
fi

# kprobe 命中每轮 +10，read events 一直 0
(
  i=1
  while [ "$i" -le 8 ]; do
    printf '  si_fix_pu  0  0\n  si_fix_pm  %s  0\n' "$((i * 10))" > "$TRACE/kprobe_profile"
    sleep 1
    i=$((i + 1))
  done
) &
UP=$!

if wait_status '"blind":1'; then
  ok "连续 2 个周期后 blind=1"
else
  bad "没有检测到假活：$(cat "$DATA/status.json" 2>/dev/null)"
fi
grep -q '"reason":"blind"' "$DATA/status.json" 2>/dev/null \
  && ok "reason=blind" || bad "reason 不是 blind：$(cat "$DATA/status.json" 2>/dev/null)"
if wait_prop '事件通道异常'; then
  ok "模块描述提示重启手机"
else
  bad "模块描述没有提示：$(grep '^description=' "$MOD/module.prop")"
fi
[ -f "$I/keepme" ] && [ "$(cat "$I/tracing_on")" = 1 ] \
  && ok "未拆实例/kprobe，tracing_on 仍为 1" || bad "实例/tracing 被改动"

# 停掉计数增长：通道仍盲，只是没流量；不能自己把 blind 清掉。
# 负例用带超时的轮询观察（每 0.1s 检查一次，任何时刻翻掉都算失败），不裸睡。
kill -9 "$UP" 2>/dev/null; UP=""
if hold_status 30 '"blind":1'; then
  ok "安静 3 秒（无 kprobe 流量）仍保持 blind=1"
else
  bad "无流量时误恢复：$(cat "$DATA/status.json" 2>/dev/null)"
fi

# 发一条真事件才允许恢复
( printf 'si_fix_pm: 1.000: path_mount\n' > "$I/trace_pipe" ) &
_i=0
while [ "$_i" -lt 50 ] && ! grep -q '"blind":0' "$DATA/status.json" 2>/dev/null; do
  sleep 0.1; _i=$((_i + 1))
done
if grep -q '"blind":0' "$DATA/status.json" 2>/dev/null; then
  ok "收到事件后 blind=0"
else
  bad "收到事件后没有恢复：$(cat "$DATA/status.json" 2>/dev/null)"
fi
grep -q '"reason":"ok"' "$DATA/status.json" 2>/dev/null \
  && ok "reason 恢复 ok" || bad "reason 没有恢复：$(cat "$DATA/status.json" 2>/dev/null)"
_i=0
while [ "$_i" -lt 50 ] && grep -q '事件通道异常' "$MOD/module.prop" 2>/dev/null; do
  sleep 0.1; _i=$((_i + 1))
done
grep -q '事件通道异常' "$MOD/module.prop" 2>/dev/null \
  && bad "描述仍停留在异常" || ok "描述恢复正常"

# 负例：A/B 同步增长（read events 跟得上 kprobe），不能误报假活
(
  i=1
  while [ "$i" -le 4 ]; do
    printf '  si_fix_pu  0  0\n  si_fix_pm  %s  0\n' "$((100 + i * 10))" > "$TRACE/kprobe_profile"
    printf 'entries: 0\noverrun: 0\nread events: %s\n' "$((100 + i * 10))" > "$I/per_cpu/cpu0/stats"
    sleep 1
    i=$((i + 1))
  done
  : > "$T/sync-done"
) &
UP=$!
# 等 updater 写完 4 轮（有上限），期间一旦误报 blind 立刻失败；
# 写完后再观察一个采样周期，替代原来的固定 sleep 4。
_flip=0
_i=0
while [ "$_i" -lt 80 ]; do
  grep -q '"blind":1' "$DATA/status.json" 2>/dev/null && { _flip=1; break; }
  [ -e "$T/sync-done" ] && break
  sleep 0.1; _i=$((_i + 1))
done
_i=0
while [ "$_i" -lt 12 ]; do
  grep -q '"blind":1' "$DATA/status.json" 2>/dev/null && { _flip=1; break; }
  sleep 0.1; _i=$((_i + 1))
done
if [ "$_flip" = 0 ] \
   && grep -q '"blind":0' "$DATA/status.json" 2>/dev/null \
   && grep -q '"reason":"ok"' "$DATA/status.json" 2>/dev/null; then
  ok "A/B 同步增长时仍 blind=0 / reason=ok（不误报）"
else
  bad "同步增长被误报：$(cat "$DATA/status.json" 2>/dev/null)"
fi
grep -q '事件通道异常' "$MOD/module.prop" 2>/dev/null \
  && bad "负例仍写异常描述" || ok "负例描述保持正常"
kill -9 "$UP" 2>/dev/null; UP=""

kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; DPID=""
kill "$WP" 2>/dev/null; WP=""

echo
[ "$fail" = 0 ] && { echo "blind.test: PASS"; exit 0; }
echo "blind.test: FAIL"; exit 1
