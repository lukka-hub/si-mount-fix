#!/system/bin/sh
# action.sh（Magisk「操作」按钮）回归：
#   1) fix 输出为空 → 必须报“执行失败（无结果行）”，不能显示“没有需要修复”；
#   2) fix 输出不是 RESULT 行 → 同样判失败；
#   3) 正常 RESULT → 仍显示体检结果，且 rollback/sandbox_skip 有中文标签；
#   4) R8：status.json 的 sandbox_stale/gone/rollback/skip 要显示在主报告里；
#   5) fix 最近一轮 error 时，沙箱状态只能标成“上次记录”（SAND_* 只在成功分支更新）；
#   6) WebUI 主状态卡/banner 读同两个字段，SKIP_LABEL 含 rollback/sandbox_skip。
#
# 用法：sh tools/action.test.sh
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1
ACTION=action.sh
# 解释器可移植：默认 Android 的 /system/bin/sh；不存在或不可执行时回退 mksh → sh。
TEST_SH=${SI_TEST_SH:-/system/bin/sh}
if ! { command -v "$TEST_SH" >/dev/null 2>&1 && "$TEST_SH" -c ':' >/dev/null 2>&1; }; then
  TEST_SH=$(command -v mksh 2>/dev/null)
fi
if [ -z "$TEST_SH" ] || ! { command -v "$TEST_SH" >/dev/null 2>&1 && "$TEST_SH" -c ':' >/dev/null 2>&1; }; then
  TEST_SH=$(command -v sh 2>/dev/null)
fi
if [ -z "$TEST_SH" ] || ! { command -v "$TEST_SH" >/dev/null 2>&1 && "$TEST_SH" -c ':' >/dev/null 2>&1; }; then
  echo "找不到可用的 sh（可用 SI_TEST_SH=... 指定）"; exit 1
fi

T=${TMPDIR:-/tmp}/si-action-test.$$
trap 'rm -rf "$T"' EXIT INT TERM HUP
MOD=$T/mod; DATA=$T/data
mkdir -p "$MOD/scripts" "$DATA" || exit 1
printf 'id=si-mount-fix\nversion=v1.4.2\nversionCode=142\nname=x\nauthor=x\ndescription=x\n' > "$MOD/module.prop"
# fix stub：输出由 SI_TEST_FIX_OUT 决定（空串=无结果行）。
cat > "$MOD/scripts/fix-si-mounts.sh" <<'S'
#!/bin/sh
printf '%s\n' "$SI_TEST_FIX_OUT"
S
chmod 755 "$MOD/scripts/fix-si-mounts.sh"

run_action() {   # $1=fix 输出；其余环境变量由调用方设好
  SI_DATA=$DATA SI_MOD=$MOD SI_SH_BIN=$TEST_SH SI_TEST_FIX_OUT=$1 \
    "$TEST_SH" "$ACTION" 2>&1
}
set_status() {   # $1=status.json 单行内容
  printf '%s\n' "$1" > "$DATA/status.json" || exit 1
}
base_status='{"mode":"event","reason":"ok","reason_text":"正常","pid":0,"since":0,"last_fixed":0,"total_fixed":0,"min_age":15,"interval":60,"tracefs":"rw","churn":0,"blind":0,"sandbox_gone":0,"sandbox_stale":0,"sandbox_rollback":0,"sandbox_skip":0}'

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# ---------- 1) 空输出：执行失败（无结果行） ----------
set_status "$base_status"
out=$(run_action "")
has "$out" '执行失败（无结果行）' && ok "空 RESULT 报执行失败" || bad "空 RESULT 没报失败：$out"
has "$out" '没有需要修复' && bad "空 RESULT 被当成“没有需要修复”：$out" \
  || ok "空 RESULT 不显示“没有需要修复”"

# ---------- 2) 非 RESULT 行：同样判失败 ----------
out=$(run_action "hello, this is not a result line")
has "$out" '执行失败（无结果行）' && ok "非 RESULT 前缀判失败" || bad "非 RESULT 没报失败：$out"
has "$out" '没有需要修复' && bad "非 RESULT 被当成正常结果：$out" || ok "非 RESULT 不显示正常结果"

# ---------- 3) 正常 RESULT + 新标签 ----------
out=$(run_action "RESULT checked=2 broken=1 fixed=0 young=0 skipped=rollback+sandbox_skip")
has "$out" '检查 2 个隔离进程' && ok "正常 RESULT 仍显示检查数" || bad "正常 RESULT 没显示：$out"
has "$out" '回滚未卸干净' && ok "rollback 有中文标签" || bad "rollback 没有标签：$out"
has "$out" '沙箱未重建' && ok "sandbox_skip 有中文标签" || bad "sandbox_skip 没有标签：$out"

# 带 retry= 的体检文案
out=$(run_action "RESULT checked=1 broken=1 fixed=0 young=0 retry=180 skipped=bindfail")
has "$out" '约 180 秒后自动重试' && ok "retry= 显示倒计时" || bad "retry= 没有显示：$out"

# identity 残留要带“需重启应用”
out=$(run_action "RESULT checked=1 broken=0 fixed=0 young=0 skipped=identity")
has "$out" '沙箱身份不符（需重启应用）' && ok "identity 标签带需重启应用" || bad "identity 标签缺提示：$out"

# ---------- 4) R8：sandbox_stale/gone 上主报告 ----------
set_status '{"mode":"event","reason":"ok","reason_text":"正常","pid":0,"since":0,"last_fixed":0,"total_fixed":0,"min_age":15,"interval":60,"tracefs":"rw","churn":0,"blind":0,"sandbox_gone":0,"sandbox_stale":1}'
out=$(run_action "RESULT checked=1 broken=0 fixed=0 young=0")
has "$out" '沙箱   僵死（需重启应用）' && ok "status.sandbox_stale=1 显示僵死" || bad "没有显示沙箱僵死：$out"

set_status '{"mode":"event","reason":"ok","reason_text":"正常","pid":0,"since":0,"last_fixed":0,"total_fixed":0,"min_age":15,"interval":60,"tracefs":"rw","churn":0,"blind":0,"sandbox_gone":1,"sandbox_stale":0,"sandbox_rollback":0,"sandbox_skip":0}'
out=$(run_action "RESULT checked=1 broken=0 fixed=0 young=0")
has "$out" '沙箱   丢失（会尝试重建）' && ok "status.sandbox_gone=1 显示丢失" || bad "没有显示沙箱丢失：$out"

set_status '{"mode":"event","reason":"ok","reason_text":"正常","pid":0,"since":0,"last_fixed":0,"total_fixed":0,"min_age":15,"interval":60,"tracefs":"rw","churn":0,"blind":0,"sandbox_gone":0,"sandbox_stale":0,"sandbox_rollback":1,"sandbox_skip":0}'
out=$(run_action "RESULT checked=1 broken=0 fixed=0 young=0")
has "$out" '沙箱   回滚未卸干净（需重启应用）' && ok "status.sandbox_rollback=1 显示回滚未卸干净" || bad "没有显示回滚状态：$out"

set_status '{"mode":"event","reason":"ok","reason_text":"正常","pid":0,"since":0,"last_fixed":0,"total_fixed":0,"min_age":15,"interval":60,"tracefs":"rw","churn":0,"blind":0,"sandbox_gone":0,"sandbox_stale":0,"sandbox_rollback":0,"sandbox_skip":1}'
out=$(run_action "RESULT checked=1 broken=0 fixed=0 young=0")
has "$out" '沙箱   未重建（安全拒绝，需重启应用）' && ok "status.sandbox_skip=1 显示安全拒绝" || bad "没有显示安全拒绝：$out"

# ---------- 5) 最近一轮 fix error：只能标成上次记录 ----------
set_status '{"mode":"event","reason":"fix_error_timeout","reason_text":"修复脚本异常：timeout","pid":0,"since":0,"last_fixed":0,"total_fixed":0,"min_age":15,"interval":60,"tracefs":"rw","churn":0,"blind":0,"sandbox_gone":0,"sandbox_stale":1}'
out=$(run_action "RESULT checked=0 broken=0 fixed=0 young=0 error=timeout")
has "$out" '上次记录：僵死' && ok "error 时沙箱状态标为上次记录" || bad "error 时把旧状态当当前：$out"

# ---------- 6) WebUI 静态断言（状态卡/banner/词表） ----------
cnt=$(grep -c 'toInt(s\.sandbox_stale, 0)' webroot/index.html 2>/dev/null)
[ "${cnt:-0}" -ge 2 ] && ok "WebUI 状态卡与 banner 都读 sandbox_stale（$cnt 处）" \
  || bad "WebUI 没有读 sandbox_stale（$cnt 处）"
cnt=$(grep -c 'toInt(s\.sandbox_gone, 0)' webroot/index.html 2>/dev/null)
[ "${cnt:-0}" -ge 2 ] && ok "WebUI 状态卡与 banner 都读 sandbox_gone（$cnt 处）" \
  || bad "WebUI 没有读 sandbox_gone（$cnt 处）"
cnt=$(grep -c 'toInt(s\.sandbox_rollback, 0)' webroot/index.html 2>/dev/null)
[ "${cnt:-0}" -ge 2 ] && ok "WebUI 状态卡与 banner 都读 sandbox_rollback（$cnt 处）" \
  || bad "WebUI 没有读 sandbox_rollback（$cnt 处）"
cnt=$(grep -c 'toInt(s\.sandbox_skip, 0)' webroot/index.html 2>/dev/null)
[ "${cnt:-0}" -ge 2 ] && ok "WebUI 状态卡与 banner 都读 sandbox_skip（$cnt 处）" \
  || bad "WebUI 没有读 sandbox_skip（$cnt 处）"
grep -q "identity: '沙箱身份不符（需重启应用）'" webroot/index.html 2>/dev/null \
  && ok "WebUI identity 标签带需重启应用" || bad "WebUI identity 标签缺提示"
grep -q "sandbox_skip: '沙箱未重建" webroot/index.html 2>/dev/null \
  && ok "WebUI SKIP_LABEL 含 sandbox_skip" || bad "WebUI 缺少 sandbox_skip 标签"
grep -q "rollback: '回滚未卸干净" webroot/index.html 2>/dev/null \
  && ok "WebUI SKIP_LABEL 含 rollback" || bad "WebUI 缺少 rollback 标签"

echo
[ "$fail" = 0 ] && { echo "action.test: PASS"; exit 0; }
echo "action.test: FAIL"; exit 1
