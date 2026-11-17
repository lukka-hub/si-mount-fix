#!/system/bin/sh
# RESULT skipped=... 的 token 解析 + 降级原因优先级
#
# 覆盖：
#   1) fix 返回 skipped=identity+locked 时，daemon 必须识别出 locked 并写
#      reason=skipped_locked（若 daemon 的解析正则把 '+' 截断，只剩 identity，
#      就会被当成成功 → 状态漂成 ok/降级原因）。
#   2) 轮询降级（POLL_REASON=tracefs_missing）不能覆盖 skipped_locked：
#      抢锁是更具体的状态，必须让用户看见“另一轮修复正在进行”。
#   两条断言分别覆盖：token 正则把 + 截断、POLL_REASON 无条件覆盖。
#
# 用法：sh tools/skiplocked.test.sh
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

T=${TMPDIR:-/tmp}/si-skiplocked-test.$$
DATA=$T/data; MOD=$T/mod; TRACE=$T/trace
DPID=""
cleanup() {
  [ -n "$DPID" ] && kill -9 "$DPID" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT INT TERM HUP
mkdir -p "$DATA" "$MOD/scripts" "$MOD/webroot" "$TRACE" || exit 1
printf 'ENABLED=1\nMODE=auto\nPOLL_INTERVAL=10\nMIN_AGE=15\n' > "$DATA/config.conf"
printf 'version=v1.4.0\nversionCode=140\ndescription=x\n' > "$MOD/module.prop"
cat > "$MOD/scripts/fix-si-mounts.sh" <<'S'
#!/bin/sh
. "$(dirname "$0")/result.sh"
case "$1" in --trim-only) exit 0 ;; esac
# 故意把 locked 放在后面：解析正则若把 '+' 截断，只会看到 identity
result_line 0 0 0 0 skipped=identity+locked
S
cp scripts/result.sh "$MOD/scripts/result.sh" || exit 1
chmod 755 "$MOD/scripts/fix-si-mounts.sh" "$MOD/scripts/result.sh"

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }
wait_status() {   # 最多 8s
  _i=0
  while [ "$_i" -lt 80 ]; do
    grep -q "$1" "$DATA/status.json" 2>/dev/null && return 0
    sleep 0.1; _i=$((_i + 1))
  done
  return 1
}

# SI_TRACE 指向没有 kprobe_events 的目录 → tracefs_missing → poll（POLL_REASON 已置位）
SI_DATA=$DATA SI_MOD=$MOD SI_TRACE=$TRACE "$DSH" "$DAEMON" >"$T/daemon.out" 2>&1 &
DPID=$!

if wait_status '"reason":"skipped_locked"'; then
  ok "skipped=identity+locked 被完整识别（token 里的 + 没被截断）"
else
  bad "locked 没被识别/被降级原因覆盖：$(cat "$DATA/status.json" 2>/dev/null)"
fi
case "$(cat "$DATA/status.json" 2>/dev/null)" in
  *'"reason_text":"另一轮修复正在进行，稍后重试"'*)
    ok "reason_text 为“另一轮修复正在进行”（未被降级原因改写）" ;;
  *) bad "reason_text 不对：$(cat "$DATA/status.json" 2>/dev/null)" ;;
esac
case "$(cat "$DATA/status.json" 2>/dev/null)" in
  *'"reason":"ok"'*|*'"reason":"tracefs_missing"'*)
    bad "skipped_locked 被洗成了 ok/降级原因" ;;
  *) ok "没有被洗成 ok 或降级原因" ;;
esac

echo
[ "$fail" = 0 ] && { echo "skiplocked.test: PASS"; exit 0; }
echo "skiplocked.test: FAIL"; exit 1
