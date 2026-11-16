#!/system/bin/sh
# 运行全部回归测试；pipebusy 约 30 秒，可用 SKIP_SLOW=1 跳过。
# 用法：sh tools/run-tests.sh
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1

fail=0
for t in identity fusewait bootwait equiv churn blind; do
  echo "== $t"
  sh "tools/$t.test.sh" || fail=1
done
if [ "$SKIP_SLOW" = 1 ]; then
  echo "== pipebusy（SKIP_SLOW=1，跳过）"
else
  echo "== pipebusy"
  sh tools/pipebusy.test.sh || fail=1
fi

echo
if [ "$fail" = 0 ]; then
  echo "all tests: PASS"
  exit 0
fi
echo "all tests: FAIL"
exit 1
