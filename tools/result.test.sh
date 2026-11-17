#!/system/bin/sh
# RESULT 行契约回归：生产 fix 与测试 stub 共用的 scripts/result.sh。
#
# 为什么需要：daemon（scripts/si-mount-eventd.sh）只靠 sed 解析 RESULT 末行的
# token，之前 3 套 daemon 测试各自手写一行 RESULT stub，生产端 token 改了，
# stub 仍输出旧格式，测试照样绿。这里锁住格式与解析，daemon 测试的 stub
# 也改成 source 同一个 scripts/result.sh。
#
# 用法：sh tools/result.test.sh
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1
RESULT_LIB=scripts/result.sh
# 解释器可移植：默认 Android 的 /system/bin/sh；不存在或不可执行（曾被替换成
# 设备节点）时回退 mksh → sh。用 `-c :` 真跑一次，比只 command -v 可靠。
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

[ -f "$RESULT_LIB" ] || { echo "缺少 $RESULT_LIB"; exit 1; }
. "./$RESULT_LIB"

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }

# daemon 的解析表达式（与 si-mount-eventd.sh run_fix 保持一致；改动那边要同步这里）
field() {   # $1=字段名 $2=RESULT 行
  printf '%s\n' "$2" | sed -n "s/.*$1=\\([a-z0-9_+]*\\).*/\\1/p" | tail -1
}

# ---------- 1) 基线格式：daemon 解析必须逐字段拿到 ----------
line=$(result_line 3 2 1 0)
[ "$line" = "RESULT checked=3 broken=2 fixed=1 young=0" ] \
  && ok "基线格式稳定：$line" || bad "基线格式变了：[$line]"
[ "$(field checked "$line")" = 3 ] && ok "daemon 解析 checked=3" || bad "checked 解析失败：$line"
[ "$(field broken "$line")" = 2 ] && ok "daemon 解析 broken=2" || bad "broken 解析失败：$line"
[ "$(field fixed "$line")" = 1 ] && ok "daemon 解析 fixed=1" || bad "fixed 解析失败：$line"
[ "$(field young "$line")" = 0 ] && ok "daemon 解析 young=0" || bad "young 解析失败：$line"

# ---------- 2) 计数容错：空/非数字一律 0，不能让 sed 取空 ----------
line=$(result_line "" abc 7 -1)
[ "$line" = "RESULT checked=0 broken=0 fixed=7 young=0" ] \
  && ok "异常计数归一为 0（sed 不会取空）" || bad "异常计数没有归一：[$line]"

# ---------- 3) 附加字段：顺序保留，daemon 都能解析 ----------
line=$(result_line 0 0 0 0 churn=2 retry=30 skipped=dir_space+identity defer=fuse)
[ "$line" = "RESULT checked=0 broken=0 fixed=0 young=0 churn=2 retry=30 skipped=dir_space+identity defer=fuse" ] \
  && ok "附加字段按传入顺序输出" || bad "附加字段顺序/内容不对：[$line]"
[ "$(field churn "$line")" = 2 ] && ok "daemon 解析 churn=2" || bad "churn 解析失败：$line"
[ "$(field retry "$line")" = 30 ] && ok "daemon 解析 retry=30" || bad "retry 解析失败：$line"
[ "$(field skipped "$line")" = dir_space+identity ] \
  && ok "daemon 解析 skipped=dir_space+identity" || bad "skipped 解析失败：$line"
[ "$(field defer "$line")" = fuse ] && ok "daemon 解析 defer=fuse" || bad "defer 解析失败：$line"

line=$(result_line 0 1 2 0 sandbox=1 skipped=sandbox_stale)
[ "$(field sandbox "$line")" = 1 ] && ok "daemon 解析 sandbox=1" || bad "sandbox 解析失败：$line"
[ "$(field skipped "$line")" = sandbox_stale ] \
  && ok "daemon 解析 skipped=sandbox_stale" || bad "stale 解析失败：$line"

line=$(result_line 0 0 0 0 error=config)
[ "$(field error "$line")" = config ] && ok "daemon 解析 error=config" || bad "error 解析失败：$line"
line=$(result_line 0 0 0 0 skipped=locked)
[ "$(field skipped "$line")" = locked ] && ok "daemon 解析 skipped=locked" || bad "skipped 解析失败：$line"

# ---------- 4) 契约违规：非法字段丢弃并返回 2，不污染已生成的字段 ----------
line=$(result_line 1 2 3 4 "BAD=x")
rc=$?
[ "$rc" = 2 ] && ok "非法 key 返回 2（契约错误可见）" || bad "非法 key 返回 $rc（应 2）"
[ "$line" = "RESULT checked=1 broken=2 fixed=3 young=4" ] \
  && ok "非法字段被丢弃，其余字段完整" || bad "非法字段污染了输出：[$line]"

line=$(result_line 1 2 3 4 "ok=has space")
rc=$?
[ "$rc" = 2 ] && [ "$line" = "RESULT checked=1 broken=2 fixed=3 young=4" ] \
  && ok "值里带空格被拒绝（daemon 用空白分词）" || bad "带空格的字段没有被拒绝：rc=$rc [$line]"

# 少于 4 个计数时，后面的 k=v 无法定位：丢弃并按契约错误返回 2（不能静默当成功）
line=$(result_line 1 2 "defer=fuse")
rc=$?
[ "$rc" = 2 ] && [ "$line" = "RESULT checked=1 broken=2 fixed=0 young=0" ] \
  && ok "少传计数返回 2（附加字段不会被静默吞掉）" \
  || bad "少传计数没有报契约错误：rc=$rc [$line]"

# 保留字段不能通过附加参数注入（daemon 的贪婪 sed 会取到伪计数）
line=$(result_line 1 2 3 4 "checked=999")
rc=$?
[ "$rc" = 2 ] && [ "$line" = "RESULT checked=1 broken=2 fixed=3 young=4" ] \
  && ok "保留字段 checked 被拒绝（不能覆盖真实计数）" \
  || bad "保留字段没有被拒绝：rc=$rc [$line]"

# 空值不能通过
line=$(result_line 1 2 3 4 "ok=")
rc=$?
[ "$rc" = 2 ] && ok "空值字段返回 2" || bad "空值字段没有报错：rc=$rc [$line]"

# daemon 风格的解析（与 scripts/si-mount-eventd.sh 同款字符集）必须能吃下完整 token
_daemon_parse() {   # $1=key $2=line
  printf '%s' "$2" | sed -n 's/.*'"$1"'=\([A-Za-z0-9_+.-]*\).*/\1/p' | tail -1
}
line=$(result_line 0 0 0 0 "skipped=Dir-A+tag2.b")
[ "$(_daemon_parse skipped "$line")" = "Dir-A+tag2.b" ] \
  && ok "daemon 风格解析能吃下大小写/点号/加号的 token" \
  || bad "daemon 风格解析截断了 token：$(_daemon_parse skipped "$line")"
line=$(result_line 0 0 0 0 "defer=FUSE" "error=exit2")
[ "$(_daemon_parse defer "$line")" = "FUSE" ] && [ "$(_daemon_parse error "$line")" = "exit2" ] \
  && ok "defer=FUSE / error=exit2 不被截断" \
  || bad "defer/error 被截断：defer=$(_daemon_parse defer "$line") error=$(_daemon_parse error "$line")"

# ---------- 5) 只输出一行、不夹带其它内容 ----------
n=$(result_line 1 1 1 1 | wc -l | tr -d ' ')
[ "$n" = 1 ] && ok "只输出一行" || bad "输出了 $n 行"

err=$(result_line 1 1 1 1 2>&1 >/dev/null)
[ -z "$err" ] && ok "不写 stderr" || bad "stderr 有输出：$err"

# ---------- 6) 解释器可移植：TEST_SH 能解析 ----------
if "$TEST_SH" -n "$RESULT_LIB" 2>/dev/null; then
  ok "$TEST_SH 能解析 $RESULT_LIB"
else
  bad "$TEST_SH 解析失败：$RESULT_LIB"
fi
"$TEST_SH" -c ". ./$RESULT_LIB; result_line 1 0 0 0" >/dev/null 2>&1 \
  && ok "$TEST_SH 能 source 并调用" || bad "$TEST_SH source 失败"

# ---------- 7) 生产端是否已接入（fix 未接入时只提示，不算测试失败） ----------
if grep -q 'result_line' scripts/fix-si-mounts.sh 2>/dev/null \
   && grep -q 'result\.sh' scripts/fix-si-mounts.sh 2>/dev/null; then
  ok "fix-si-mounts.sh 已 use 共享 result_line"
else
  echo "  note fix-si-mounts.sh 尚未 source scripts/result.sh（不算失败）"
fi

# ---------- 8) daemon 测试 stub 必须走共享实现，不能再手写 RESULT ----------
leak=""
for f in tools/bootwait.test.sh tools/blind.test.sh tools/pipebusy.test.sh; do
  [ -f "$f" ] || continue
  # stub 里出现字面量 "RESULT checked=" 说明又漂回手写格式了
  grep -q 'RESULT checked=' "$f" && leak="$leak $f"
  grep -q 'result\.sh' "$f" || leak="$leak $f(未 source)"
done
[ -z "$leak" ] && ok "3 套 daemon 测试 stub 都走 scripts/result.sh" \
  || bad "stub 仍手写 RESULT 或未 source：$leak"

# ---------- 9) fix 可能输出的 skipped token 必须有中文标签 ----------
# 漏一个标签，action/WebUI 就会把英文 token 原样显示给用户；rollback 是新加的，
# 但这里把所有 token 一起锁住，避免以后再漏。
missing=""
for tok in locked disabled identity layer source source_ns bindfail \
           sandbox_gone sandbox_stale sandbox_skip rollback churn \
           template dir_space dir_invalid; do
  grep -q "^[[:space:]]*$tok)" action.sh 2>/dev/null || missing="$missing action:$tok"
  grep -q "^[[:space:]]*$tok:" webroot/index.html 2>/dev/null || missing="$missing webui:$tok"
done
[ -z "$missing" ] && ok "skipped 的每个 token 在 action/WebUI 都有标签" \
  || bad "缺少标签：$missing"

echo
[ "$fail" = 0 ] && { echo "result.test: PASS"; exit 0; }
echo "result.test: FAIL"; exit 1
