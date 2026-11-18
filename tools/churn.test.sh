#!/system/bin/sh
# 4.2 修复熔断回归（真实 fix 脚本 + 假 /proc + 会改 mountinfo 的 nsenter stub）
#
# 覆盖：
#   A) 正常修一次不熔断；300 秒内第 3 次成功修复后，第 4 次检测熔断
#   B) 熔断后 now < until 不动；now >= until 允许重试一次，成功后清状态
#   C) 重试仍失败 → block；block 状态下不再尝试
#   D) dry-run 不写 .repairs/.churn、不熔断
#   E) --trim-only 清旧记录/限 200 行/清 .churn
#   G) 同包多 PID 去重；同轮失败时 churn 累加不被扫描 Z 行覆盖
#
# 用法：sh tools/churn.test.sh
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1
FIX=scripts/fix-si-mounts.sh
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

T=${TMPDIR:-/tmp}/si-churn-test.$$
trap 'rm -rf "$T"' EXIT INT TERM HUP
P=$T/proc; BIN=$T/bin; DATA=$T/data; SRC=$T/mnt/user/0/emulated
mkdir -p "$P/self" "$P/101" "$P/102" "$BIN" "$DATA" "$SRC" || exit 1
# 动手前会再读 pid 的 starttime/uid/ns：给被修复的 pid 造 stat/status。
mkproc() {   # $1=pid $2=starttime
  _i=0; _f=""
  while [ "$_i" -lt 18 ]; do _f="$_f 0"; _i=$((_i + 1)); done
  printf '%s (com.churn) S%s %s\n' "$1" "$_f" "$2" > "$P/$1/stat"
  printf 'Name:\tcom.churn\nUid:\t0\t0\t0\t0\n' > "$P/$1/status"
}
mkproc 101 1000
mkproc 102 1001
# 动手前还要比对 namespace：给两个 pid 造 ns/mnt 链接。
mkdir -p "$P/101/ns" "$P/102/ns" || exit 1
ln -sf 'mnt:[4026532101]' "$P/101/ns/mnt"
ln -sf 'mnt:[4026532101]' "$P/102/ns/mnt"

cat > "$P/self/mountinfo" <<'M'
100 1 0:50 / / rw - ext4 /dev/root rw
101 100 0:50 / /mnt/user/0/emulated rw - fuse /dev/fuse rw
102 100 0:50 / /storage/emulated rw - fuse /dev/fuse rw
M
cat > "$T/conf.json" <<'J'
{"mount_dirs_templates":[{"id":"t1","list":["DCIM"]}],"apps":[{"package_name":"com.churn","enabled":true,"mount_dirs":true,"template_ids":["t1"]}]}
J
cat > "$BIN/ps" <<'S'
#!/bin/sh
cat <<'P'
  PID   UID     ELAPSED ARGS
  101     0    10:00 com.churn
P
[ "$SI_TEST_PS_EXTRA" = 1 ] && printf '  102     0    10:00 com.churn\n'
S
# nsenter stub：bind 往 mountinfo 追加一条 DCIM；umount 删除它；test -d 恒真。
# 多 PID 用例设 SI_TEST_MI_DIR=<proc 根>，按 -t 的 PID 改各自的 mountinfo。
cat > "$BIN/nsenter" <<'S'
#!/bin/sh
pid=""; prev=""
for a in "$@"; do
  [ "$prev" = "-t" ] && pid=$a
  prev=$a
done
mi=$SI_TEST_MI
[ -n "$SI_TEST_MI_DIR" ] && [ -n "$pid" ] && mi=$SI_TEST_MI_DIR/$pid/mountinfo
case " $* " in
  *" test -d "*) exit 0 ;;
  *" mount --bind "*)
    [ "$SI_TEST_BIND_FAIL" = 1 ] && exit 1
    [ -n "$SI_TEST_BIND_SLEEP" ] && sleep "$SI_TEST_BIND_SLEEP"
    echo "201 200 0:50 /0/DCIM /storage/emulated/0/DCIM rw - fuse /dev/fuse rw" >> "$mi"
    exit 0 ;;
  *" umount -l "*)
    grep -v ' /storage/emulated/0/DCIM ' "$mi" > "$mi.tmp" 2>/dev/null
    mv -f "$mi.tmp" "$mi" 2>/dev/null
    exit 0 ;;
esac
exit 1
S
chmod 755 "$BIN/ps" "$BIN/nsenter"

mkdir -p "$DATA/media/0/Android/data/com.churn/sdcard/DCIM" "$SRC/0/DCIM" || exit 1
MI=$P/101/mountinfo

root_mi() {
  cat > "$MI" <<'M'
200 1 0:50 /0/Android/data/com.churn/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
M
}
break_mi() {
  grep -v ' /storage/emulated/0/DCIM ' "$MI" > "$MI.tmp" 2>/dev/null
  mv -f "$MI.tmp" "$MI" 2>/dev/null
}
# 同包第二个 PID（102）的 mountinfo：坏 = 只有沙箱根；健康 = 根 + 已挂 DCIM。
multi_broken_mi() {
  cat > "$P/102/mountinfo" <<'M'
200 1 0:50 /0/Android/data/com.churn/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
M
}
multi_healthy_mi() {
  cat > "$P/102/mountinfo" <<'M'
200 1 0:50 /0/Android/data/com.churn/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
201 200 0:50 /0/DCIM /storage/emulated/0/DCIM rw - fuse /dev/fuse rw
M
}

run2() {   # 单独数据目录，$1=now $2=bind-fail
  SI_TEST=1 SI_PROC=$P SI_CONF=$T/conf.json SI_DATA=$DATA2 \
    SI_TEST_DATA=$DATA SI_TEST_SRC=$SRC SI_TEST_NOW=$1 SI_TEST_MONO=$1 \
    SI_TEST_MI=$MI SI_TEST_BIND_FAIL=$2 SI_MIN_AGE=5 SI_FUSE_WAIT=1 \
    PATH=$BIN:$PATH "$TEST_SH" "$FIX" -q 2>&1
}
run() {   # $1=now $2=bind-fail
  SI_TEST=1 SI_PROC=$P SI_CONF=$T/conf.json SI_DATA=$DATA \
    SI_TEST_DATA=$DATA SI_TEST_SRC=$SRC SI_TEST_NOW=$1 SI_TEST_MONO=$1 \
    SI_TEST_MI=$MI SI_TEST_BIND_FAIL=$2 SI_MIN_AGE=5 SI_FUSE_WAIT=1 \
    PATH=$BIN:$PATH "$TEST_SH" "$FIX" -q 2>&1
}
run_dry() {
  SI_TEST=1 SI_PROC=$P SI_CONF=$T/conf.json SI_DATA=$DATA \
    SI_TEST_DATA=$DATA SI_TEST_SRC=$SRC SI_TEST_NOW=$1 SI_TEST_MONO=$1 \
    SI_TEST_MI=$MI SI_TEST_BIND_FAIL=0 SI_MIN_AGE=5 SI_FUSE_WAIT=1 \
    PATH=$BIN:$PATH "$TEST_SH" "$FIX" -n -q 2>&1
}
run_multi() {   # $1=now $2=数据目录；ps 多报同包 PID 102，bind 改各自 mountinfo
  SI_TEST=1 SI_PROC=$P SI_CONF=$T/conf.json SI_DATA=$2 \
    SI_TEST_DATA=$DATA SI_TEST_SRC=$SRC SI_TEST_NOW=$1 SI_TEST_MONO=$1 \
    SI_TEST_MI=$MI SI_TEST_MI_DIR=$P SI_TEST_PS_EXTRA=1 SI_TEST_BIND_FAIL=0 \
    SI_MIN_AGE=5 SI_FUSE_WAIT=1 PATH=$BIN:$PATH "$TEST_SH" "$FIX" -q 2>&1
}
run_multi_fail() {   # 多 PID 且 bind 失败：第一个 PID 熔断，第二个 PID 走失败退避
  SI_TEST=1 SI_PROC=$P SI_CONF=$T/conf.json SI_DATA=$2 \
    SI_TEST_DATA=$DATA SI_TEST_SRC=$SRC SI_TEST_NOW=$1 SI_TEST_MONO=$1 \
    SI_TEST_MI=$MI SI_TEST_MI_DIR=$P SI_TEST_PS_EXTRA=1 SI_TEST_BIND_FAIL=1 \
    SI_MIN_AGE=5 SI_FUSE_WAIT=1 PATH=$BIN:$PATH "$TEST_SH" "$FIX" -q 2>&1
}

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }
result() { printf '%s\n' "$1" | sed -n 's/^RESULT //p' | tail -1; }

# ---------- A) 三次成功修复后熔断 ----------
now=1700000000
root_mi
out=$(run "$now" 0); r=$(result "$out")
case "$r" in *"fixed=1"*) ok "A1 第一次修复 fixed=1" ;; *) bad "A1 第一次没有修复：$r" ;; esac
break_mi
out=$(run 1700000010 0); r=$(result "$out")
case "$r" in *"fixed=1"*) ok "A2 第二次修复 fixed=1" ;; *) bad "A2 第二次没有修复：$r" ;; esac
break_mi
out=$(run 1700000020 0); r=$(result "$out")
case "$r" in *"fixed=1"*) ok "A3 第三次修复 fixed=1" ;; *) bad "A3 第三次没有修复：$r" ;; esac
break_mi
out=$(run 1700000030 0); r=$(result "$out")
case "$r" in *"churn=1"*"skipped=churn"*|*"skipped=churn"*"churn=1"*) ok "A4 第 4 次检测熔断（churn=1）" ;; *) bad "A4 没有熔断：$r" ;; esac
case "$r" in *"fixed=0"*) ok "A4 熔断时不修复" ;; *) bad "A4 熔断时仍修复：$r" ;; esac
grep -q '^com.churn|DCIM|1700000630|wait$' "$DATA/.churn" 2>/dev/null \
  && ok "A4 .churn 记录 wait 到 +600s" || bad "A4 .churn 状态不对：$(cat "$DATA/.churn" 2>/dev/null)"
n_fixed=$(grep -c ' fixed' "$DATA/.repairs" 2>/dev/null)
[ "$n_fixed" = 3 ] && ok "A4 .repairs 只有 3 次成功记录" || bad "A4 .repairs fixed 记录=$n_fixed"

# ---------- B) until 前不动，到点重试成功 ----------
out=$(run 1700000629 0); r=$(result "$out")
case "$r" in *"churn=1"*) ok "B1 未到重试时间仍熔断" ;; *) bad "B1 提前重试：$r" ;; esac
case "$r" in *"fixed=0"*) ok "B1 未到重试时间不修复" ;; *) bad "B1 未到重试时间仍修复：$r" ;; esac
break_mi
out=$(run 1700000630 0); r=$(result "$out")
case "$r" in *"fixed=1"*) ok "B2 到 10 分钟重试成功 fixed=1" ;; *) bad "B2 重试没有修复：$r" ;; esac
case "$r" in *"churn=1"*) bad "B2 重试成功仍报 churn：$r" ;; *) ok "B2 重试成功清掉 churn" ;; esac
[ ! -s "$DATA/.churn" ] && ok "B2 .churn 已清空" || bad "B2 .churn 未清空：$(cat "$DATA/.churn" 2>/dev/null)"

# ---------- C) 重试失败 → block ----------
# 重新制造 3 次成功修复（时间窗口内）
break_mi
run 1700001000 0 >/dev/null
break_mi
run 1700001010 0 >/dev/null
break_mi
run 1700001020 0 >/dev/null
break_mi
out=$(run 1700001030 0); r=$(result "$out")
case "$r" in *"churn=1"*) ok "C1 再次熔断" ;; *) bad "C1 没有熔断：$r" ;; esac
break_mi
out=$(run 1700001630 1); r=$(result "$out")
case "$r" in *"churn=1"*) ok "C2 重试失败进入 block" ;; *) bad "C2 重试失败未熔断：$r" ;; esac
case "$r" in *"skipped="*"churn"*) ok "C2 RESULT 标记 skipped=churn" ;; *) bad "C2 没有 skipped=churn：$r" ;; esac
grep -q '^com.churn|DCIM|.*|block$' "$DATA/.churn" 2>/dev/null \
  && ok "C2 .churn=block（带 1 小时 TTL）" || bad "C2 .churn 不是 block：$(cat "$DATA/.churn" 2>/dev/null)"
break_mi
out=$(run 1700002630 0); r=$(result "$out")
case "$r" in *"churn=1"*) ok "C3 block 后不再尝试" ;; *) bad "C3 block 后仍尝试：$r" ;; esac
case "$r" in *"fixed=0"*) ok "C3 block 后 fixed=0" ;; *) bad "C3 block 后仍修复：$r" ;; esac
break_mi
out=$(run 1700005231 0); r=$(result "$out")
case "$r" in *"fixed=1"*) ok "C4 block 1 小时 TTL 到期后可重试成功" ;; *) bad "C4 TTL 到期没有重试：$r" ;; esac

# ---------- C2) <1 秒判据：同秒内再次被拆必熔断 ----------
DATA2=$T/data-fast
rm -rf "$DATA2"; root_mi
out=$(run2 1700002000 0); r=$(result "$out")
case "$r" in *"fixed=1"*) ok "C2 首次修复" ;; *) bad "C2 首次没有修复：$r" ;; esac
break_mi
out=$(run2 1700002000 0); r=$(result "$out")
case "$r" in *"churn=1"*) ok "C2 同秒再拆 → churn=1（<1 秒判据）" ;; *) bad "C2 没有按 <1 秒熔断：$r" ;; esac
case "$r" in *"fixed=0"*) ok "C2 同秒再拆不重复修复" ;; *) bad "C2 同秒仍修复：$r" ;; esac

# ---------- C3) 慢 bind 跨秒：证明记的是完成时刻（ms），不是扫描开始 ----------
DATA_MS=$T/data-ms
run_real() {   # $1=bind-sleep；真实时钟
  SI_TEST=1 SI_PROC=$P SI_CONF=$T/conf.json SI_DATA=$DATA_MS \
    SI_TEST_DATA=$DATA SI_TEST_SRC=$SRC SI_TEST_MI=$MI \
    SI_TEST_BIND_FAIL=0 SI_TEST_BIND_SLEEP=$1 SI_MIN_AGE=5 SI_FUSE_WAIT=1 \
    PATH=$BIN:$PATH "$TEST_SH" "$FIX" -q 2>&1
}
rm -rf "$DATA_MS"; rm -f "$DATA/.churn"; root_mi
out=$(run_real 1.2); r=$(result "$out")
case "$r" in *"fixed=1"*) ok "C3 慢 bind 1.2s 完成 fixed=1" ;; *) bad "C3 慢 bind 没有修复：$r" ;; esac
break_mi
out=$(run_real ""); r=$(result "$out")
case "$r" in *"churn=1"*) ok "C3 完成时刻后 <1 秒再拆 → churn=1（ms 时间戳）" ;; *) bad "C3 ms 判据没有熔断：$r" ;; esac

# ---------- D) dry-run 不写状态 ----------
rm -rf "$DATA/.repairs" "$DATA/.churn"
root_mi
out=$(run_dry 1700003000); r=$(result "$out")
case "$r" in *"broken=1"*"fixed=0"*) ok "D1 dry-run 报告 broken=1 fixed=0" ;; *) bad "D1 dry-run 结果不对：$r" ;; esac
[ ! -e "$DATA/.repairs" ] && [ ! -e "$DATA/.churn" ] \
  && ok "D2 dry-run 不写 .repairs/.churn" || bad "D2 dry-run 写了状态文件"

# ---------- E) --trim-only ----------
now=1700004000
{
  i=0
  while [ "$i" -lt 205 ]; do
    echo "$((now - 7200 + i)) com.old T$i fixed"
    i=$((i + 1))
  done
  echo "$((now - 60)) com.keep DCIM fixed"
  echo "$((now - 50)).500 com.keep2 DCIM fixed"
} > "$DATA/.repairs"
printf 'com.churn|DCIM|0|block\n' > "$DATA/.churn"
SI_TEST=1 SI_DATA=$DATA SI_TEST_NOW=$now "$TEST_SH" "$FIX" --trim-only >/dev/null 2>&1
lines=$(wc -l < "$DATA/.repairs" 2>/dev/null)
[ "$lines" -le 200 ] && ok "E1 --trim-only 后 ≤200 行（$lines）" || bad "E1 仍是 $lines 行"
grep -q 'com.keep DCIM fixed' "$DATA/.repairs" && ok "E2 保留 1 小时内记录" || bad "E2 误删新记录"
grep -q 'com.keep2 DCIM fixed' "$DATA/.repairs" && ok "E2 保留秒.毫秒格式记录" || bad "E2 误删小数时间记录"
[ ! -e "$DATA/.churn" ] && ok "E3 --trim-only 清 .churn" || bad "E3 .churn 未清"

# ---------- F) .repairs 200 行上限（repair 追加时裁剪）----------
now=1700004000
{
  i=0
  while [ "$i" -lt 205 ]; do
    echo "$((now - 100 + i)) com.old T$i fixed"
    i=$((i + 1))
  done
} > "$DATA/.repairs"
rm -f "$DATA/.churn"
root_mi
out=$(run "$now" 0); r=$(result "$out")
case "$r" in *"fixed=1"*) ok "F1 205 行历史下仍能修复" ;; *) bad "F1 没有修复：$r" ;; esac
lines=$(wc -l < "$DATA/.repairs" 2>/dev/null)
[ "$lines" -eq 200 ] && ok "F2 .repairs 追加后正好 200 行" || bad "F2 .repairs 行数=$lines"

# ---------- G) 同包多 PID：成功与 churn 清理都按 (pkg,target) 去重 ----------
DATA_M=$T/data-multi
rm -rf "$DATA_M"
root_mi
multi_broken_mi
out=$(run_multi 1700007000 "$DATA_M"); r=$(result "$out")
case "$r" in *"checked=2"*) ok "G1 同包 2 个 PID 都被扫描" ;; *) bad "G1 没有扫描到 2 个 PID：$r" ;; esac
case "$r" in *"fixed=1"*) ok "G1 两个 PID 同目标都坏，fixed=1" ;; *) bad "G1 fixed 重复计数：$r" ;; esac
n_fixed=$(grep -c ' fixed' "$DATA_M/.repairs" 2>/dev/null)
[ "$n_fixed" = 1 ] && ok "G1 .repairs 只有 1 条 fixed" || bad "G1 .repairs fixed 记录=$n_fixed"
grep -q ' /storage/emulated/0/DCIM ' "$P/101/mountinfo" 2>/dev/null \
  && grep -q ' /storage/emulated/0/DCIM ' "$P/102/mountinfo" 2>/dev/null \
  && ok "G1 每个 PID 都实际补挂了 DCIM" || bad "G1 有 PID 没被实际修复"

DATA_M2=$T/data-multi-churn
rm -rf "$DATA_M2"; mkdir -p "$DATA_M2"
root_mi
multi_healthy_mi
printf 'com.churn|DCIM|1700007600|wait\n' > "$DATA_M2/.churn"
out=$(run_multi 1700007000 "$DATA_M2"); r=$(result "$out")
case "$r" in *"fixed=0"*) ok "G2 熔断窗口内不修复" ;; *) bad "G2 不应修复：$r" ;; esac
case "$r" in *"churn=1"*) ok "G2 坏 PID 仍被判 churn=1" ;; *) bad "G2 churn 计数不对：$r" ;; esac
grep -qxF 'com.churn|DCIM|1700007600|wait' "$DATA_M2/.churn" 2>/dev/null \
  && ok "G2 健康 PID 没有清掉同包的 .churn" \
  || bad "G2 .churn 被误清：$(cat "$DATA_M2/.churn" 2>/dev/null)"

# G3) 同包两个 PID：第一个 retry 失败熔断，第二个走 180s 退避；
#     churn 由 shell 即时累加，不能被 Z 行的扫描计数覆盖成 0。
DATA_M3=$T/data-multi-churn-new
rm -rf "$DATA_M3"; mkdir -p "$DATA_M3"
root_mi
multi_broken_mi
printf 'com.churn|DCIM|1700007000|wait\n' > "$DATA_M3/.churn"
out=$(run_multi_fail 1700008000 "$DATA_M3"); r=$(result "$out")
case "$r" in *"churn=1"*) ok "G3 第一个 PID 失败熔断后 churn=1（未被 Z 行覆盖）" ;; \
  *) bad "G3 churn 被 Z 行覆盖：$r" ;; esac
case "$r" in *"retry=180"*) ok "G3 第二个 PID 走 180s 失败退避" ;; \
  *) bad "G3 第二个 PID 没有按 180s 退避：$r" ;; esac
case "$r" in *"fixed=0"*) ok "G3 失败轮 fixed=0" ;; *) bad "G3 失败轮仍计 fixed：$r" ;; esac
case "$r" in *"skipped="*"churn"*) ok "G3 RESULT 标记 skipped=churn" ;; *) bad "G3 没有 skipped=churn：$r" ;; esac
n=$(grep -c ' com.churn DCIM failed' "$DATA_M3/.repairs" 2>/dev/null)
[ "$n" = 1 ] && ok "G3 只写一条失败退避行（第二个 PID 被退避挡住）" \
  || bad "G3 失败退避行数不对：$n"
grep -qxF 'com.churn|DCIM|1700011600|block' "$DATA_M3/.churn" 2>/dev/null \
  && ok "G3 .churn 行为不变（失败后 block 1 小时）" \
  || bad "G3 .churn 状态不对：$(cat "$DATA_M3/.churn" 2>/dev/null)"

echo
[ "$fail" = 0 ] && { echo "churn.test: PASS"; exit 0; }
echo "churn.test: FAIL"; exit 1
