#!/system/bin/sh
# pipe_busy / 复用回归（真实守护脚本，mksh 跑事件/poll 循环）
# 用法：sh tools/pipebusy.test.sh
#
# 覆盖：
#   B) 实例在、trace_pipe 打不开且无 holder（ELOOP）→ 先尝试重建，成功则 event
#   C) CFG_MODE=poll → 完全不做 event 探测，直接 run_fix + poll_loop（含第二周期）
#   D) 实例存在、tracing_on=1、kprobe 都在 → 复用（不删 kprobe、不 rmdir）
#   E) 实例存在、tracing_on=1、但 kprobe 缺失 → 重建后 event/ok 且 kprobe 重新出现
#   A) 真有 holder（FIFO 读者）→ poll/pipe_busy，不碰实例；释放后退出重进事件模式
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1
DAEMON=scripts/si-mount-eventd.sh
DSH=${SI_TEST_SHELL:-mksh}
command -v "$DSH" >/dev/null 2>&1 || DSH=/system/bin/sh
command -v "$DSH" >/dev/null 2>&1 || { echo "需要 mksh（read -t）"; exit 1; }
REAL_MKDIR=$(command -v mkdir) || { echo "缺少 mkdir"; exit 1; }

T=${TMPDIR:-/tmp}/si-pipebusy-test.$$
DATA=$T/data; MOD=$T/mod; TRACE=$T/trace; I=$TRACE/instances/si_mount_fix
DPID=""; HP=""; WP=""
cleanup() {
  for _p in "$DPID" "$HP" "$WP"; do
    [ -n "$_p" ] && kill -9 "$_p" 2>/dev/null
  done
  [ -f "$T/rebuild-writer.pid" ] && kill -9 "$(cat "$T/rebuild-writer.pid" 2>/dev/null)" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT INT TERM HUP

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }

mkdir -p "$T/bin" || exit 1
# 重建路径的 stub：实例被重建时补出 events/kprobes/* 与一个新的 trace_pipe 读者
cat > "$T/bin/mkdir" <<'S'
#!/bin/sh
"$SI_TEST_REAL_MKDIR" "$@"; _rc=$?
for _a in "$@"; do
  case "$_a" in
    */instances/si_mount_fix)
      "$SI_TEST_REAL_MKDIR" -p "$_a/events/kprobes/si_fix_pu" "$_a/events/kprobes/si_fix_pm" 2>/dev/null
      : > "$_a/events/kprobes/si_fix_pu/enable"
      : > "$_a/events/kprobes/si_fix_pm/enable"
      mkfifo "$_a/trace_pipe" 2>/dev/null
      ( exec 8<> "$_a/trace_pipe"; exec sleep 60 ) &
      [ -n "$SI_TEST_WRITER_PID" ] && echo $! > "$SI_TEST_WRITER_PID"
      ;;
  esac
done
exit $_rc
S
# 自检 stub：向 fake trace 追加两条事件，让重建后的自检通过
cat > "$T/bin/unshare" <<'S'
#!/bin/sh
[ -n "$SI_TEST_TRACE_FILE" ] || exit 0
echo si_fix_pm >> "$SI_TEST_TRACE_FILE" 2>/dev/null
echo si_fix_pu >> "$SI_TEST_TRACE_FILE" 2>/dev/null
exit 0
S
chmod 755 "$T/bin/mkdir" "$T/bin/unshare"

reset_fixture() {   # $1=config MODE
  rm -rf "$T/data" "$T/mod" "$T/trace" "$T/fix.log" "$T/rebuild-writer.pid"
  mkdir -p "$DATA" "$MOD/scripts" "$MOD/webroot" "$I/events/kprobes/si_fix_pm" \
           "$I/events/kprobes/si_fix_pu" "$TRACE/events/kprobes/si_fix_pm" \
           "$TRACE/events/kprobes/si_fix_pu" || exit 1
  printf 'ENABLED=1\nMODE=%s\nPOLL_INTERVAL=10\nMIN_AGE=15\n' "$1" > "$DATA/config.conf"
  printf 'version=v1.3.4\nversionCode=134\ndescription=x\n' > "$MOD/module.prop"
  cat > "$MOD/scripts/fix-si-mounts.sh" <<'S'
#!/bin/sh
# 启动时 daemon 会先调 --trim-only；它不算一次真实 run_fix
case "$1" in --trim-only) exit 0 ;; esac
echo run >> "$SI_TEST_FIX_LOG"
echo "RESULT checked=0 broken=0 fixed=0 young=0"
S
  chmod 755 "$MOD/scripts/fix-si-mounts.sh"
  printf 'p:si_fix_pu path_umount\np:si_fix_pm path_mount\n' > "$TRACE/kprobe_events"
  cp -f "$TRACE/kprobe_events" "$T/kprobe.before"
  echo 1 > "$I/tracing_on"
  echo 1 > "$I/events/enable"
  echo 1 > "$I/events/kprobes/si_fix_pm/enable"
  echo 1 > "$I/events/kprobes/si_fix_pu/enable"
  echo 1 > "$TRACE/events/kprobes/si_fix_pm/enable"
  echo 1 > "$TRACE/events/kprobes/si_fix_pu/enable"
  echo keep > "$I/keepme"
}

start_daemon() {
  SI_DATA=$DATA SI_MOD=$MOD SI_TRACE=$TRACE SI_TEST_FIX_LOG=$T/fix.log \
    SI_TEST_TRACE_FILE=$I/trace SI_TEST_WRITER_PID=$T/rebuild-writer.pid \
    SI_TEST_REAL_MKDIR="$REAL_MKDIR" PATH=$T/bin:$PATH \
    "$DSH" "$DAEMON" >"$T/daemon.out" 2>&1 &
  DPID=$!
}
stop_daemon() {
  [ -n "$DPID" ] || return 0
  kill "$DPID" 2>/dev/null
  _i=0
  while [ "$_i" -lt 50 ] && kill -0 "$DPID" 2>/dev/null; do
    sleep 0.1; _i=$((_i+1))
  done
  kill -9 "$DPID" 2>/dev/null
  wait "$DPID" 2>/dev/null
  DPID=""
}
kill_rebuild_writer() {
  if [ -f "$T/rebuild-writer.pid" ]; then
    kill -9 "$(cat "$T/rebuild-writer.pid" 2>/dev/null)" 2>/dev/null
  fi
}
wait_status() {   # $1=字符串
  _i=0
  while [ "$_i" -lt 120 ]; do
    grep -q "$1" "$DATA/status.json" 2>/dev/null && return 0
    sleep 0.1; _i=$((_i+1))
  done
  return 1
}
wait_fix() {
  _i=0
  while [ "$_i" -lt 120 ]; do
    [ -s "$T/fix.log" ] && return 0
    sleep 0.1; _i=$((_i+1))
  done
  return 1
}
assert_untouched() {   # $1=场景名
  [ -f "$I/keepme" ] && ok "$1：实例 sentinel 还在（未 rmdir）" || bad "$1：实例被拆"
  [ "$(cat "$TRACE/kprobe_events" 2>/dev/null)" = "$(cat "$T/kprobe.before" 2>/dev/null)" ] \
    && ok "$1：kprobe_events 未变（未删 kprobe）" || bad "$1：kprobe 被删/被建"
  [ "$(cat "$I/tracing_on" 2>/dev/null)" = 1 ] \
    && ok "$1：tracing_on 未被关" || bad "$1：tracing_on 被改"
  [ "$(cat "$I/events/enable" 2>/dev/null)" = 1 ] \
    && ok "$1：events/enable 未被关" || bad "$1：events/enable 被改"
}

# ---------- B) 打不开 + 无 holder → 先尝试重建 ----------
reset_fixture auto
ln -s trace_pipe "$I/trace_pipe"     # 自环 = ELOOP，且没有持有者
start_daemon
if wait_status '"mode":"event"'; then
  ok "B) 无 holder 坏实例 → 重建后进入 event"
else
  bad "B) 没有重建回 event：$(cat "$DATA/status.json" 2>/dev/null)"
fi
wait_fix && ok "B) 启动 run_fix 执行" || bad "B) 启动没有 run_fix"
grep -q 'p:si_fix_pu' "$TRACE/kprobe_events" 2>/dev/null \
  && grep -q 'p:si_fix_pm' "$TRACE/kprobe_events" 2>/dev/null \
  && ok "B) kprobe 已重新注册" || bad "B) kprobe 没有重新注册"
[ -e "$I/events/kprobes/si_fix_pu/enable" ] && [ -e "$I/events/kprobes/si_fix_pm/enable" ] \
  && ok "B) 实例内 kprobe 事件已重建" || bad "B) 实例内 kprobe 事件缺失"
stop_daemon
kill_rebuild_writer

# ---------- C) 强制 poll：不做 event 探测 + 第二周期仍轮询 ----------
reset_fixture poll
ln -s trace_pipe "$I/trace_pipe"
start_daemon
wait_fix && ok "C) MODE=poll 直接 run_fix" || bad "C) MODE=poll 没有 run_fix"
wait_status '"mode":"poll"' && ok "C) status mode=poll" || bad "C) 没有进入 poll"
case "$(cat "$DATA/status.json" 2>/dev/null)" in
  *pipe_busy*|*pipe_open_error*) bad "C) 强制 poll 仍做了 event 探测：$(cat "$DATA/status.json")" ;;
  *) ok "C) 强制 poll 未做 event 探测" ;;
esac
assert_untouched C
_c1=$(wc -l < "$T/fix.log" 2>/dev/null || echo 0)
_i=0
while [ "$_i" -lt 150 ] && [ "$(wc -l < "$T/fix.log" 2>/dev/null || echo 0)" -le "$_c1" ]; do
  sleep 0.1; _i=$((_i+1))
done
[ "$(wc -l < "$T/fix.log" 2>/dev/null || echo 0)" -gt "$_c1" ] \
  && ok "C) 第二个 POLL_INTERVAL 周期仍在 run_fix" \
  || bad "C) 第二周期没有 run_fix"
stop_daemon

# ---------- D) 实例在、tracing_on=1、kprobe 在 → 复用 ----------
reset_fixture auto
mkfifo "$I/trace_pipe"
sh -c 'exec 8<> "$1"; exec sleep 60' _ "$I/trace_pipe" &
WP=$!
start_daemon
if wait_status '"mode":"event"'; then
  ok "D) 复用已有实例并进入 event"
else
  bad "D) 没有复用：$(cat "$DATA/status.json" 2>/dev/null)"
fi
wait_fix && ok "D) 启动 run_fix 执行" || bad "D) 启动没有 run_fix"
assert_untouched D
stop_daemon
kill "$WP" 2>/dev/null; WP=""
kill_rebuild_writer

# ---------- E) 实例在、tracing_on=1、但 kprobe 缺失 → 重建 ----------
reset_fixture auto
: > "$TRACE/kprobe_events"
mkfifo "$I/trace_pipe"
sh -c 'exec 8<> "$1"; exec sleep 60' _ "$I/trace_pipe" &
WP=$!
start_daemon
if wait_status '"mode":"event"'; then
  ok "E) kprobe 缺失时重建并进入 event"
else
  bad "E) kprobe 缺失时没有重建：$(cat "$DATA/status.json" 2>/dev/null)"
fi
wait_fix && ok "E) 重建后 run_fix 执行" || bad "E) 重建后没有 run_fix"
grep -q 'p:si_fix_pu' "$TRACE/kprobe_events" 2>/dev/null \
  && grep -q 'p:si_fix_pm' "$TRACE/kprobe_events" 2>/dev/null \
  && ok "E) kprobe 已重新注册" || bad "E) kprobe 没有重新注册"
[ -e "$I/events/kprobes/si_fix_pu/enable" ] && [ -e "$I/events/kprobes/si_fix_pm/enable" ] \
  && ok "E) 实例内 kprobe 事件存在" || bad "E) 实例内 kprobe 事件缺失"
[ -s "$T/rebuild-writer.pid" ] && ok "E) 重建时 trace_pipe 重新可用" || bad "E) 重建后 trace_pipe 不可用"
stop_daemon
kill "$WP" 2>/dev/null; WP=""
kill_rebuild_writer

# ---------- A) 真有 holder（FIFO 读者）→ pipe_busy，释放后退出 ----------
reset_fixture auto
mkfifo "$I/trace_pipe"
( exec 8> "$I/trace_pipe"; exec sleep 1 ) &
TW=$!
sh -c 'exec 9< "$1"; exec sleep 60' _ "$I/trace_pipe" &
HP=$!
_i=0
while [ "$_i" -lt 50 ] && [ ! -e "/proc/$HP/fd/9" ]; do sleep 0.1; _i=$((_i+1)); done
sleep 1
kill "$TW" 2>/dev/null; wait "$TW" 2>/dev/null
[ -e "/proc/$HP/fd/9" ] && ok "A) holder 已持有 FIFO（fd 9）" || bad "A) holder 没有打开 FIFO"
_t0=$(date +%s)
start_daemon
if wait_status '"reason":"pipe_busy"'; then
  _t1=$(date +%s)
  grep -q '"mode":"poll"' "$DATA/status.json" && ok "A) 有 holder → poll/pipe_busy" \
    || bad "A) mode 不是 poll：$(cat "$DATA/status.json")"
  _el=$((_t1 - _t0))
  [ "$_el" -le 5 ] && ok "A) busy 结论 ≤5s（实测 ${_el}s）" \
    || bad "A) busy 结论超过 5s（实测 ${_el}s）"
else
  bad "A) 没有识别出 holder：$(cat "$DATA/status.json" 2>/dev/null)"
fi
wait_fix && ok "A) 降级前先 run_fix 一次" || bad "A) 降级前没有 run_fix"
sleep 0.5
_kids=$(cat "/proc/$DPID/task/$DPID/children" 2>/dev/null)
_lk=0
for _k in $_kids; do
  _kc=$(tr '\0' ' ' < "/proc/$_k/cmdline" 2>/dev/null)
  case "$_kc" in
    sleep*) ;;
    *timeout*|*readlink*|*grep*|*"ls -l"*) bad "A) 残留探测子进程：$_kc"; _lk=1 ;;
  esac
done
[ "$_lk" = 0 ] && ok "A) 无残留探测子进程"
assert_untouched A
kill "$HP" 2>/dev/null; HP=""
# holder 释放后给一个 writer，下一次重探就能打开 pipe；守护应 exit 0 交 supervisor
( exec 8> "$I/trace_pipe"; exec sleep 30 ) &
WP=$!
_i=0
while [ "$_i" -lt 200 ] && kill -0 "$DPID" 2>/dev/null; do sleep 0.1; _i=$((_i+1)); done
if kill -0 "$DPID" 2>/dev/null; then
  bad "A) pipe 空出后没有退出重进事件模式"
  stop_daemon
else
  wait "$DPID" 2>/dev/null; _rc=$?; DPID=""
  [ "$_rc" = 0 ] && ok "A) pipe 空出后 exit 0（交 supervisor 重启）" \
    || bad "A) 退出码不是 0：$_rc"
fi
kill "$WP" 2>/dev/null; WP=""

echo
[ "$fail" = 0 ] && { echo "pipebusy.test: PASS"; exit 0; }
echo "pipebusy.test: FAIL"; exit 1
