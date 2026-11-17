#!/system/bin/sh
# 真实 daemon 链路回归：fix 的 skipped=rollback+sandbox_skip 必须进入 status.json，
# 并且 action / WebUI 能读到这两个字段（不能只测手写 status.json）。
#
# 覆盖：
#   1) 真实 si-mount-eventd.sh 跑一轮 fix stub → status.json 写
#      sandbox_rollback=1 / sandbox_skip=1，同时 gone/stale 保持 0；
#   2) action.sh 读真实 status.json 后显示“回滚未卸干净/安全拒绝”；
#   3) 同一份 .sandbox_report 连续两轮只记一次日志（去重不丢赋值）。
#
# 用法：sh tools/statuschain.test.sh
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1
DAEMON=scripts/si-mount-eventd.sh
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

T=${TMPDIR:-/tmp}/si-statuschain-test.$$
DATA=$T/data; MOD=$T/mod; TRACE=$T/trace
DPID=""
cleanup() {
  [ -n "$DPID" ] && kill -9 "$DPID" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT INT TERM HUP
mkdir -p "$DATA" "$MOD/scripts" "$MOD/webroot" "$TRACE" || exit 1
printf 'ENABLED=1\nMODE=auto\nPOLL_INTERVAL=10\nMIN_AGE=15\n' > "$DATA/config.conf"
printf 'version=v1.4.2\nversionCode=142\ndescription=x\n' > "$MOD/module.prop"
cp scripts/result.sh "$MOD/scripts/result.sh" || exit 1
cat > "$MOD/scripts/fix-si-mounts.sh" <<'S'
#!/bin/sh
. "$(dirname "$0")/result.sh"
case "$1" in --trim-only) exit 0 ;; esac
# 每轮都写同一份报告：用来验证 daemon 不会重复记日志。
: > "$SI_DATA/.sandbox_report"
echo "skip com.victim" >> "$SI_DATA/.sandbox_report"
result_line 0 0 0 0 skipped=rollback+sandbox_skip
S
chmod 755 "$MOD/scripts/fix-si-mounts.sh" "$MOD/scripts/result.sh"

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }
wait_status() {   # 最多 10s
  _i=0
  while [ "$_i" -lt 100 ]; do
    grep -q "$1" "$DATA/status.json" 2>/dev/null && return 0
    sleep 0.1; _i=$((_i + 1))
  done
  return 1
}

# SI_TRACE 指向没有 kprobe_events 的目录 → 轮询模式，daemon 会正常跑 fix。
SI_DATA=$DATA SI_MOD=$MOD SI_TRACE=$TRACE "$DSH" "$DAEMON" >"$T/daemon.out" 2>&1 &
DPID=$!

if wait_status '"sandbox_rollback":1' && wait_status '"sandbox_skip":1'; then
  ok "真实 daemon 把 rollback/sandbox_skip 写进 status.json"
else
  bad "status.json 没有 rollback/skip 字段：$(cat "$DATA/status.json" 2>/dev/null)"
fi
st=$(cat "$DATA/status.json" 2>/dev/null)
case "$st" in
  *'"sandbox_gone":0'*) ok "rollback/skip 不把 sandbox_gone 带成 1" ;;
  *) bad "sandbox_gone 状态不对：$st" ;;
esac
case "$st" in
  *'"sandbox_stale":0'*) ok "rollback/skip 不把 sandbox_stale 带成 1" ;;
  *) bad "sandbox_stale 状态不对：$st" ;;
esac

# 等第二轮 poll（POLL_INTERVAL=10）：同一份报告只应记一次日志。
sleep 12
n=$(grep -c '沙箱未重建' "$DATA/daemon.log" 2>/dev/null)
[ "${n:-0}" = 1 ] && ok "同一份 sandbox_report 连续两轮只记一次日志（$n）" \
  || bad "sandbox_report 日志重复（$n 次）：$(grep '沙箱未重建' "$DATA/daemon.log" 2>/dev/null)"

# 停掉 daemon，换一个只输出正常 RESULT 的 fix，让 action 的“沙箱”行只来自 status.json。
kill -9 "$DPID" 2>/dev/null
DPID=""
sleep 0.2
cat > "$MOD/scripts/fix-si-mounts.sh" <<'S'
#!/bin/sh
. "$(dirname "$0")/result.sh"
case "$1" in --trim-only) exit 0 ;; esac
result_line 0 0 0 0
S
chmod 755 "$MOD/scripts/fix-si-mounts.sh"

out=$(SI_DATA=$DATA SI_MOD=$MOD SI_SH_BIN=$DSH "$DSH" action.sh 2>&1)
case "$out" in
  *'沙箱   '*"回滚未卸干净（需重启应用）"*) ok "action 显示回滚未卸干净" ;;
  *) bad "action 没显示回滚状态：$out" ;;
esac
case "$out" in
  *'沙箱   '*"未重建（安全拒绝，需重启应用）"*) ok "action 显示安全拒绝" ;;
  *) bad "action 没显示安全拒绝：$out" ;;
esac
case "$out" in
  *"上次记录"*) bad "无 fix_error 却标成上次记录：$out" ;;
  *) ok "reason 正常时不标上次记录" ;;
esac

echo
[ "$fail" = 0 ] && { echo "statuschain.test: PASS"; exit 0; }
echo "statuschain.test: FAIL"; exit 1
