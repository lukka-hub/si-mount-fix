#!/system/bin/sh
# 轮询降级原因 vs 真实修复错误
#
# 覆盖：
#   1) 轮询降级（tracefs 缺失）期间 fix 报错 → status 必须是 fix_error_config，
#      不能被 POLL_REASON 覆盖成 tracefs_missing（否则面板/按钮看不到真实错误）。
#   2) fix 恢复正常 → 降级原因仍要可见（reason 回到 tracefs_missing），
#      不能被本轮 ok 洗成 ok。
#
# 用法：sh tools/pollreason.test.sh
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1
DAEMON=scripts/si-mount-eventd.sh
# 解释器可移植：默认 Android 的 /system/bin/sh；不存在/不可执行时回退 mksh → sh。
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

T=${TMPDIR:-/tmp}/si-pollreason-test.$$
DATA=$T/data; MOD=$T/mod; TRACE=$T/trace
DPID=""
cleanup() {
  [ -n "$DPID" ] && kill -9 "$DPID" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT INT TERM HUP
mkdir -p "$DATA" "$MOD/scripts" "$MOD/webroot" "$TRACE" || exit 1
# POLL_INTERVAL 最小 10s；本次用例只等 1~2 个周期
printf 'ENABLED=1\nMODE=auto\nPOLL_INTERVAL=10\nMIN_AGE=15\n' > "$DATA/config.conf"
printf 'version=v1.4.0\nversionCode=140\ndescription=x\n' > "$MOD/module.prop"
echo error > "$T/fix-mode"
# fix stub：按 $SI_TEST_FIX_MODE 返回 error=config 或成功；RESULT 格式走真实 result.sh
cat > "$MOD/scripts/fix-si-mounts.sh" <<'S'
#!/bin/sh
. "$(dirname "$0")/result.sh"
case "$(cat "$SI_TEST_FIX_MODE" 2>/dev/null)" in
  error) result_line 0 0 0 0 error=config; exit 2 ;;
  *)     result_line 0 0 0 0 ;;
esac
S
cp scripts/result.sh "$MOD/scripts/result.sh" || exit 1
chmod 755 "$MOD/scripts/fix-si-mounts.sh" "$MOD/scripts/result.sh"

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }
wait_status() {   # $1=grep 模式；最多 15s
  _i=0
  while [ "$_i" -lt 150 ]; do
    grep -q "$1" "$DATA/status.json" 2>/dev/null && return 0
    sleep 0.1; _i=$((_i + 1))
  done
  return 1
}

# SI_TRACE 指向一个没有 kprobe_events 的目录 → 守护走 tracefs_missing → poll
SI_DATA=$DATA SI_MOD=$MOD SI_TRACE=$TRACE SI_TEST_FIX_MODE=$T/fix-mode \
  "$DSH" "$DAEMON" >"$T/daemon.out" 2>&1 &
DPID=$!

if wait_status '"reason":"fix_error_config"'; then
  ok "轮询降级期间 fix 报错 → reason=fix_error_config（未被 POLL_REASON 覆盖）"
else
  bad "fix 错误被降级原因覆盖：$(cat "$DATA/status.json" 2>/dev/null)"
fi
case "$(cat "$DATA/status.json" 2>/dev/null)" in
  *'"reason_text":"修复脚本异常：config"'*)
    ok "reason_text 同步为修复脚本异常" ;;
  *) bad "reason_text 没跟上：$(cat "$DATA/status.json" 2>/dev/null)" ;;
esac

# 恢复正常：下一轮应恢复降级原因 tracefs_missing（而不是 ok）
echo ok > "$T/fix-mode"
if wait_status '"reason":"tracefs_missing"'; then
  ok "fix 恢复后降级原因仍可见（reason=tracefs_missing）"
else
  bad "降级原因被本轮 ok 洗掉：$(cat "$DATA/status.json" 2>/dev/null)"
fi
case "$(cat "$DATA/status.json" 2>/dev/null)" in
  *'"mode":"poll"'*) ok "仍处于轮询模式" ;;
  *) bad "mode 不是 poll：$(cat "$DATA/status.json" 2>/dev/null)" ;;
esac

echo
[ "$fail" = 0 ] && { echo "pollreason.test: PASS"; exit 0; }
echo "pollreason.test: FAIL"; exit 1
