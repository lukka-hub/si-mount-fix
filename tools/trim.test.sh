#!/system/bin/sh
# --trim-only 的临时文件裁剪：只清 PID 已退出或明显过期的，活 PID 的新文件保留。
#
# 覆盖：
#   A) 活 PID + 新鲜文件：.si-out.dry / .si-conf / .si-parsed / .conf.cache.tmp 都保留；
#   B) PID 已退出：四类临时文件被清掉（不管文件多新）；
#   C) 活 PID 但文件过期（早于 N 分钟）：被清掉；
#   D) .si-fixed/.si-seen 同样按这条规则；固定名 .si-out.fix 不动；
#   E) .repairs 过期行与 .churn 仍按原行为清理。
#
# 用法：sh tools/trim.test.sh
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1
FIX=scripts/fix-si-mounts.sh
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

T=${TMPDIR:-/tmp}/si-trim-test.$$
DATA=$T/data
SLOW=""
cleanup() {
  [ -n "$SLOW" ] && kill -9 "$SLOW" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT INT TERM HUP
mkdir -p "$DATA" || exit 1

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }

# 找到一个确实已经退出的 pid。
DEAD=""
i=0
while [ "$i" -lt 5 ]; do
  sh -c 'exit 0' &
  DEAD=$!
  wait "$DEAD" 2>/dev/null
  [ -d "/proc/$DEAD" ] || break
  DEAD=""
  i=$((i + 1))
done
[ -n "$DEAD" ] || { echo "拿不到已退出的 pid，无法测试"; exit 1; }
# 一个活着的 PID：文件过期时也要能被识别为“活 PID + 过期”。
sleep 60 &
SLOW=$!
LIVE=$$

NOW=$(date +%s)
case "$NOW" in ''|*[!0-9]*) NOW=1700000000 ;; esac
OLD=$((NOW - 7200))
# touch -t 用固定旧时间；与 NOW 的差远大于 30 分钟阈值。
touch -t 202001010000 "$DATA/.si-out.dry.$SLOW" "$DATA/.si-conf.$SLOW" \
  "$DATA/.si-parsed.$SLOW" "$DATA/.conf.cache.tmp.$SLOW" \
  "$DATA/.si-fixed.$SLOW" "$DATA/.si-seen.$SLOW" 2>/dev/null || exit 1

# A) 活 PID + 新文件
for n in .si-out.dry .si-conf .si-parsed .conf.cache.tmp .si-fixed .si-seen; do
  : > "$DATA/$n.$LIVE" || exit 1
done
# B) 已退出的 PID
for n in .si-out.dry .si-conf .si-parsed .conf.cache.tmp .si-fixed .si-seen; do
  : > "$DATA/$n.$DEAD" || exit 1
done
# C) 活 PID + 过期文件（上面 touch 过的六个）
# D) 固定输出名与历史遗留名
: > "$DATA/.si-out.fix" || exit 1
: > "$DATA/.si-allow.legacy" || exit 1
# E) 旧的 .repairs 行与 .churn
printf '%s com.old DCIM fixed\n' "$OLD" > "$DATA/.repairs" || exit 1
printf '%s com.keep DCIM fixed\n' "$NOW" >> "$DATA/.repairs" || exit 1
printf 'com.keep|DCIM|0|block\n' > "$DATA/.churn" || exit 1

SI_TEST=1 SI_DATA="$DATA" SI_TEST_NOW="$NOW" "$TEST_SH" "$FIX" --trim-only >/dev/null 2>&1
rc=$?
[ "$rc" = 0 ] && ok "--trim-only 正常退出（rc=0）" || bad "--trim-only 退出码 $rc"

# A) 活 PID 的新文件全部保留
kept=1
for n in .si-out.dry .si-conf .si-parsed .conf.cache.tmp .si-fixed .si-seen; do
  [ -e "$DATA/$n.$LIVE" ] || { kept=0; bad "活 PID 的新文件被删：$n.$LIVE"; }
done
[ "$kept" = 1 ] && ok "活 PID 的新鲜临时文件全部保留"
# B) 死 PID 的文件全部清掉
gone=1
for n in .si-out.dry .si-conf .si-parsed .conf.cache.tmp .si-fixed .si-seen; do
  [ ! -e "$DATA/$n.$DEAD" ] || { gone=0; bad "死 PID 的临时文件没清：$n.$DEAD"; }
done
[ "$gone" = 1 ] && ok "PID 已退出的临时文件全部清掉"
# C) 活 PID 但过期
expired=1
for n in .si-out.dry .si-conf .si-parsed .conf.cache.tmp .si-fixed .si-seen; do
  [ ! -e "$DATA/$n.$SLOW" ] || { expired=0; bad "活 PID 的过期文件没清：$n.$SLOW"; }
done
[ "$expired" = 1 ] && ok "活 PID 但超过阈值的临时文件被清掉"
# D) 固定名不动
[ -e "$DATA/.si-out.fix" ] && ok "固定输出 .si-out.fix 保留" || bad "固定输出被误删"
[ ! -e "$DATA/.si-allow.legacy" ] && ok "历史遗留 .si-allow.* 仍按原行为清理" \
  || bad "历史遗留文件没清"
# E) .repairs / .churn
grep -q 'com.old DCIM fixed' "$DATA/.repairs" 2>/dev/null \
  && bad "过期 .repairs 行没清" || ok "过期 .repairs 行已清"
grep -q 'com.keep DCIM fixed' "$DATA/.repairs" 2>/dev/null \
  && ok "1 小时内的 .repairs 行保留" || bad "新 .repairs 行被误删"
[ ! -e "$DATA/.churn" ] && ok ".churn 已清" || bad ".churn 未清"

echo
[ "$fail" = 0 ] && { echo "trim.test: PASS"; exit 0; }
echo "trim.test: FAIL"; exit 1
