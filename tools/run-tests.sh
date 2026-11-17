#!/system/bin/sh
# 运行全部测试：动态发现 tools/*.test.sh（新增测试不用改这里）。
#
# 用法：
#   sh tools/run-tests.sh                 # 全部
#   SKIP_SLOW=1 sh tools/run-tests.sh     # 跳过慢测试（pipebusy 约 30 秒）
#   sh tools/run-tests.sh fusewait blind  # 只跑指定测试
#
# 环境：
#   SI_TEST_SH     测试与待测脚本使用的 shell（默认 /system/bin/sh，缺失回退 mksh/sh）
#   TMPDIR         临时目录（Android 上 /tmp 不可写，需设为 /data/local/tmp 之类）
#   SKIP_SLOW=1    跳过慢测试
# 退出码：0 全部通过（SKIP_SLOW 时只代表跑过的都通过）；1 有失败。
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1

# 测试解释器可移植：默认 Android 的 /system/bin/sh；不存在或不可执行时回退
# mksh → sh（用 `-c :` 真跑一次，避免把设备节点之类当成 shell）。
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

# 慢测试（按测试名）：SKIP_SLOW=1 时跳过，并在结尾明确说“不是全量”。
SLOW_TESTS="pipebusy"
is_slow() {
  case " $SLOW_TESTS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

ONLY="$*"
ran=0; failed=""; skipped=""
start=$(date +%s)

for f in tools/*.test.sh; do
  [ -f "$f" ] || continue
  name=${f##*/}
  name=${name%.test.sh}
  if [ -n "$ONLY" ]; then
    case " $ONLY " in
      *" $name "*) ;;
      *) continue ;;
    esac
  fi
  if [ "$SKIP_SLOW" = 1 ] && is_slow "$name"; then
    echo "== $name（SKIP_SLOW=1，跳过）"
    skipped="$skipped $name"
    continue
  fi
  echo "== $name"
  ran=$((ran + 1))
  if "$TEST_SH" "$f"; then
    :
  else
    rc=$?
    failed="$failed $name(rc=$rc)"
  fi
done

if [ "$ran" -eq 0 ]; then
  echo "没有可运行的测试（tools/*.test.sh；过滤条件：${ONLY:-无}）" >&2
  exit 1
fi

end=$(date +%s)
echo
echo "跑了 $ran 个测试，用时 $((end - start))s"
if [ -n "$failed" ]; then
  echo "failed:$failed"
  echo "tests: FAIL"
  exit 1
fi
if [ -n "$skipped" ]; then
  echo "skipped:$skipped（慢测试未跑，不是全量结果）"
  echo "selected tests: PASS"
  exit 0
fi
echo "all tests: PASS"
exit 0
