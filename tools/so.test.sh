#!/system/bin/sh
# 实验性 `so` 子命令自测：只覆盖 fail-closed 与用法路径（不需要真实 .so）。
# 用法：sh tools/so.test.sh
#
# 覆盖：
#   1) `so` 无子命令 → 用法 + rc1
#   2) 目标模块目录不存在 → SO_STATE=no-target，rc0
#   3) 未知版本的 .so → SO_STATE=unknown，SO_BACKUP_OK=0
#   4) unknown 时 apply/restore 必须拒绝，且文件哈希不变
#   5) unknown 且没有有效备份时，`restore --force` 也必须拒绝（rc5）
#   6) `so check` 输出 9 个契约键，且不创建数据目录（只读）
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1
PATCH=scripts/si-patch.sh

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

T=${TMPDIR:-/tmp}/si-so-test.$$
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/data" "$T/mod-a/zygisk" "$T/mod-empty" || exit 1

ok=0; bad=0
pass() { ok=$((ok + 1)); echo "  ok   $1"; }
fail() { bad=$((bad + 1)); echo "  FAIL $1"; }

run_so() {   # run_so <target-dir> <args...>
  _td=$1; shift
  SI_TEST=1 SI_PATCH_DATA="$T/data" SI_PATCH_TARGET_DIR="$_td" \
    "$TEST_SH" "$PATCH" so "$@" 2>&1
}
rc_of() {   # rc_of <target-dir> <args...>
  _td=$1; shift
  SI_TEST=1 SI_PATCH_DATA="$T/data" SI_PATCH_TARGET_DIR="$_td" \
    "$TEST_SH" "$PATCH" so "$@" >/dev/null 2>&1
  echo $?
}

echo "== 1. 用法"
out=$(run_so "$T/mod-empty"); rc=$?
if [ "$rc" = 1 ] && echo "$out" | grep -q 'so check|apply|restore'; then
  pass "无子命令给出用法且 rc1"
else
  fail "无子命令用法/rc 不对（rc=$rc out=$out）"
fi

echo "== 2. 目标不存在"
out=$(run_so "$T/nope" check); rc=$?
if [ "$rc" = 0 ] && echo "$out" | grep -q '^SO_STATE=no-target$'; then
  pass "no-target"
else
  fail "no-target 不对（rc=$rc out=$out）"
fi

echo "== 3. 未知版本 .so"
printf 'not-a-real-so\n' > "$T/mod-a/zygisk/arm64-v8a.so"
before=$(sha256sum "$T/mod-a/zygisk/arm64-v8a.so" | awk '{print $1}')
out=$(run_so "$T/mod-a" check); rc=$?
if [ "$rc" = 0 ] && echo "$out" | grep -q '^SO_STATE=unknown$' \
   && echo "$out" | grep -q '^SO_UNKNOWN=arm64-v8a$' \
   && echo "$out" | grep -q '^SO_BACKUP_OK=0$'; then
  pass "未知版本报 unknown 且备份状态为 0"
else
  fail "unknown 状态输出不对（rc=$rc out=$out）"
fi

echo "== 4. unknown 时 apply/restore 必须拒绝"
rc=$(rc_of "$T/mod-a" apply)
after=$(sha256sum "$T/mod-a/zygisk/arm64-v8a.so" | awk '{print $1}')
if [ "$rc" = 4 ] && [ "$before" = "$after" ]; then
  pass "apply 拒绝且文件未变"
else
  fail "apply 未按预期拒绝（rc=$rc before=$before after=$after）"
fi
rc=$(rc_of "$T/mod-a" restore)
after=$(sha256sum "$T/mod-a/zygisk/arm64-v8a.so" | awk '{print $1}')
if [ "$rc" = 4 ] && [ "$before" = "$after" ]; then
  pass "restore 拒绝且文件未变"
else
  fail "restore 未按预期拒绝（rc=$rc）"
fi

echo "== 5. unknown + 无有效备份：restore --force 也必须拒绝"
rc=$(rc_of "$T/mod-a" restore --force)
after=$(sha256sum "$T/mod-a/zygisk/arm64-v8a.so" | awk '{print $1}')
if [ "$rc" = 5 ] && [ "$before" = "$after" ]; then
  pass "restore --force 无备份时拒绝且文件未变"
else
  fail "restore --force 行为不对（rc=$rc）"
fi

echo "== 6. check 契约键 + 只读"
out=$(run_so "$T/mod-a" check)
missing=""
for k in SO_STATE SO_MODULE SO_TARGET_VERSION SO_DIR SO_PRESENT SO_ORIGINAL \
         SO_PATCHED SO_UNKNOWN SO_BACKUP_OK SO_BACKUP_MISSING; do
  echo "$out" | grep -q "^$k=" || missing="$missing $k"
done
if [ -z "$missing" ]; then
  pass "check 输出契约键齐全"
else
  fail "check 缺键:$missing"
fi
if [ -d "$T/data" ] && [ -z "$(ls -A "$T/data" 2>/dev/null)" ]; then
  pass "check 未往数据目录写东西"
else
  fail "check 写入了数据目录（只读承诺被破坏）"
fi

echo
echo "so.test: $ok ok / $bad fail"
[ "$bad" = 0 ] || exit 1
exit 0
