#!/system/bin/sh
# 4.1 全扫提速的严格等价回归：
#   同一份 fixture（假 /proc + ps stub + 冻结配置 + 假源目录）分别跑
#   1.3.4 基线与 1.3.5 新脚本的 `-n -v`，要求 stdout/RESULT 逐字一致。
#
# 基线脚本 tools/fixtures/fix-1.3.4.baseline.sh 只把两个固定路径常量
# （/data/media、/mnt/user/0/emulated）替换到临时目录；逻辑一字未改。
# 新脚本走 SI_TEST=1 的 SI_TEST_DATA / SI_TEST_SRC 测试钩子。
#
# 用法：sh tools/equiv.test.sh   （需要 awk/ps stub，不需要 root、不碰真机路径）
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1
FIX=scripts/fix-si-mounts.sh
# 基线脚本与新脚本必须用同一个解释器跑，否则 diff 没有意义。
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
BASE=tools/fixtures/fix-1.3.4.baseline.sh
[ -f "$BASE" ] || { echo "缺少基线脚本 $BASE"; exit 1; }

T=${TMPDIR:-/tmp}/si-equiv-test.$$
trap 'rm -rf "$T"' EXIT INT TERM HUP
P=$T/proc; BIN=$T/bin; DATA=$T/data; SRC=$T/mnt/user/0/emulated
mkdir -p "$P/self" "$BIN" "$T/failbin" "$DATA" "$SRC" || exit 1

# 本机 FUSE 设备号；fixture 里沙箱层也是 0:50
cat > "$P/self/mountinfo" <<'M'
100 1 0:50 / / rw - ext4 /dev/root rw
101 100 0:50 / /mnt/user/0/emulated rw - fuse /dev/fuse rw
102 100 0:50 / /storage/emulated rw - fuse /dev/fuse rw
M

cat > "$T/conf.json" <<'J'
{"mount_dirs_templates":[{"id":"t1","list":["DCIM","Music","Pictures","Download","Documents"]}],"apps":[
{"package_name":"com.enabled","enabled":true,"mount_dirs":true,"template_ids":["t1"]},
{"package_name":"com.disabled","enabled":false,"mount_dirs":true,"template_ids":["t1"]},
{"package_name":"com.young","enabled":true,"mount_dirs":true,"template_ids":["t1"]},
{"package_name":"com.victim","enabled":true,"mount_dirs":true,"template_ids":["t1"]},
{"package_name":"com.layer","enabled":true,"mount_dirs":true,"template_ids":["t1"]},
{"package_name":"shared-com.shared","enabled":true,"mount_dirs":true,"template_ids":["t1"]},
{"package_name":"com.nosandbox","enabled":true,"mount_dirs":true,"template_ids":["t1"]},
{"package_name":"com.sub","enabled":true,"mount_dirs":true,"template_ids":["t1"]},
{"package_name":"com.empty","enabled":true,"mount_dirs":true,"template_ids":["t1"]},
{"package_name":"com.noroot","enabled":true,"mount_dirs":true,"template_ids":["t1"]},
{"package_name":"com.lostsandbox","enabled":true,"mount_dirs":true,"template_ids":["t1"]}
]}
J

cat > "$BIN/ps" <<'S'
#!/bin/sh
cat <<'P'
  PID   UID     ELAPSED ARGS
  101     0    10:00 com.enabled
  102     0    10:00 com.disabled
  103     0    00:03 com.young
  104     0    10:00 com.victim
  105     0    10:00 com.layer
  106     0    10:00 com.shared
  107     0    10:00 com.nosandbox
  108     0    10:00 com.sub
  109     0    10:00 com.empty
  110     0    10:00 com.noroot
  111     0    10:00 com.old
  113     0    10:00 com.lostsandbox
  112 101234    10:00 com.enabled
P
S
chmod 755 "$BIN/ps"
# 非 dry-run 的 repair 对照：源检查通过，mount/umount 一律失败；
# 新旧都应走到“校验失败/回滚”，RESULT 一致。
cat > "$BIN/nsenter" <<'S'
#!/bin/sh
case " $* " in
  *" test -d "*) exit 0 ;;
esac
exit 1
S
chmod 755 "$BIN/nsenter"
# 缓存命中时绝不能调用 cp；用一个会失败的 cp stub 证明
cat > "$T/failbin/cp" <<'S'
#!/bin/sh
echo called >> "$SI_TEST_CP_LOG"
exit 1
S
chmod 755 "$T/failbin/cp"

mkdir -p "$P/101" "$P/102" "$P/103" "$P/104" "$P/105" "$P/106" "$P/107" "$P/108" "$P/109" "$P/111" "$P/113"

# 101 com.enabled：DCIM 叠两层、Pictures 正常、Download 别的层、
#     Music/Documents 缺失、Android data 正常、media/obb 缺失。
cat > "$P/101/mountinfo" <<'M'
200 1 0:50 /0/Android/data/com.enabled/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
201 200 0:50 /0/DCIM /storage/emulated/0/DCIM rw - fuse /dev/fuse rw
202 200 0:50 /0/DCIM /storage/emulated/0/DCIM rw - fuse /dev/fuse rw
203 200 0:50 /0/Pictures /storage/emulated/0/Pictures rw - fuse /dev/fuse rw
204 200 0:99 /0/Download /storage/emulated/0/Download rw - ext4 /dev/x rw
205 200 0:50 /0/Android/data/com.enabled /storage/emulated/0/Android/data/com.enabled rw - fuse /dev/fuse rw
M
# 102 disabled：有故障也不动
cat > "$P/102/mountinfo" <<'M'
200 1 0:50 /0/Android/data/com.disabled/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
M
# 103 young：太年轻
cat > "$P/103/mountinfo" <<'M'
200 1 0:50 /0/Android/data/com.young/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
M
# 104 身份不符：cmdline com.victim，沙箱根 com.attacker
cat > "$P/104/mountinfo" <<'M'
200 1 0:50 /0/Android/data/com.attacker/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
M
# 105 沙箱层不是 FUSE 层
cat > "$P/105/mountinfo" <<'M'
200 1 0:99 /0/Android/data/com.layer/sdcard /storage/emulated/0 rw - ext4 /dev/x rw
M
# 106 shared- 别名
cat > "$P/106/mountinfo" <<'M'
200 1 0:50 /0/Android/data/shared-com.shared/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
M
# 107 没有沙箱根
cat > "$P/107/mountinfo" <<'M'
201 1 0:50 /0/DCIM /storage/emulated/0/DCIM rw - fuse /dev/fuse rw
M
# 108 普通包（子进程 pkg:push 由 sandbox.test 覆盖）
cat > "$P/108/mountinfo" <<'M'
200 1 0:50 /0/Android/data/com.sub/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
M
# 109 空 mountinfo：只算 checked
: > "$P/109/mountinfo"
# 111 配置里没有的包：只算 checked
cat > "$P/111/mountinfo" <<'M'
200 1 0:50 /0/Android/data/com.old/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
M
# 113 沙箱丢失但源目录不存在：1.3.4 与新版都应保持静默（新版走 G 后资格不通过）。
# 这条让 equiv 覆盖沙箱分支：把 sandbox_eligible 改坏成恒真会多出日志/RESULT 差异。
cat > "$P/113/mountinfo" <<'M'
101 100 0:50 / /mnt/user/0/emulated rw - fuse /dev/fuse rw
102 100 0:50 / /storage/emulated rw - fuse /dev/fuse rw
M

# 假源目录：$DATA/media/0/... 与 $SRC/0/...
for pkg in com.enabled com.disabled com.young com.shared com.sub; do
  root=$DATA/media/0/Android/data/$pkg/sdcard
  mkdir -p "$root/DCIM" "$root/Music" "$root/Pictures" "$root/Download" "$root/Documents" \
           "$root/Android/data" "$root/Android/media" "$root/Android/obb" 2>/dev/null
  mkdir -p "$SRC/0/DCIM" "$SRC/0/Music" "$SRC/0/Pictures" "$SRC/0/Download" "$SRC/0/Documents" \
           "$SRC/0/Android/data/$pkg" "$SRC/0/Android/media/$pkg" "$SRC/0/Android/obb/$pkg" 2>/dev/null
  mkdir -p "$DATA/media/0/Android/data/$pkg" "$DATA/media/0/Android/media/$pkg" "$DATA/media/0/Android/obb/$pkg" 2>/dev/null
done

# 基线只替换路径常量；逻辑不动
sed -e "s|/data/media|$DATA/media|g" \
    -e "s|/mnt/user/0/emulated|$SRC|g" \
    "$BASE" > "$T/old.sh" || exit 1
chmod 755 "$T/old.sh"

run_fix() {   # $1=script $2=data-dir $3=out（会清空数据目录）
  rm -rf "$2"; mkdir -p "$2" || exit 1
  run_fix_keep "$1" "$2" "$3"
}
run_fix_keep() {   # 不清数据目录：用于验证缓存命中
  SI_TEST=1 SI_PROC=$P SI_CONF=$T/conf.json SI_DATA=$2 \
    SI_MIN_AGE=15 SI_FUSE_WAIT=1 \
    SI_TEST_DATA=$DATA SI_TEST_SRC=$SRC \
    PATH=$BIN:$PATH "$TEST_SH" "$1" -n -v > "$3" 2>&1
  clean_out "$3"
}

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }

# 1.3.4 基线用 `awk -v re=...\.` 传包名正则：gawk 会往 stderr 打
# “escape sequence `\.' treated as plain `.'”，mawk 不打。这是基线写法导致的
# 告警，不是新旧实现的输出差异；只丢这一行，其余 stderr 原样保留（真错误仍会让 diff 失败）。
clean_out() {
  [ -f "$1" ] || return 0
  grep -v '^awk: warning: escape sequence' "$1" > "$1.chk" 2>/dev/null
  mv -f "$1.chk" "$1" 2>/dev/null
}

run_fix "$T/old.sh" "$T/data-old" "$T/old.out"
run_fix "$FIX" "$T/data-new" "$T/new.out"

# 两侧都启动失败时 diff 也会“相等”，所以先要求两侧都有输出。
if [ ! -s "$T/old.out" ] || [ ! -s "$T/new.out" ]; then
  bad "等价测试两侧输出为空（启动失败？），拒绝判绿"
elif diff -u "$T/old.out" "$T/new.out" > "$T/diff.txt" 2>&1; then
  ok "1.3.4 与 1.3.5 的 -n -v 输出逐字一致（$(wc -l < "$T/new.out") 行）"
else
  bad "输出不一致："
  sed -n '1,80p' "$T/diff.txt"
fi

old_res=$(tail -1 "$T/old.out")
new_res=$(tail -1 "$T/new.out")
if [ -z "$old_res" ] || [ -z "$new_res" ]; then
  bad "RESULT 为空（old=[$old_res] new=[$new_res]）"
elif [ "$old_res" = "$new_res" ]; then
  ok "RESULT 逐字一致：$new_res"
else
  bad "RESULT 不一致：old=[$old_res] new=[$new_res]"
fi

case "$new_res" in
  *error=*) bad "等价用例出现 error：$new_res" ;;
  *) ok "等价用例无 error" ;;
esac

# 缓存命中：第二次应与第一次完全一致（且不再读配置）
# -n 不得写缓存：用一个干净数据目录跑一次 dry-run
rm -rf "$T/data-nocache"; mkdir -p "$T/data-nocache"
run_fix_keep "$FIX" "$T/data-nocache" "$T/nocache.out"
[ ! -e "$T/data-nocache/.conf.cache" ] \
  && ok "-n 不写 .conf.cache" || bad "-n 仍写了 .conf.cache"

# 用一次非 dry 扫描建缓存（nsenter 失败，不会真改挂载），再验证真正的命中
rm -rf "$T/data-cache"; mkdir -p "$T/data-cache"
SI_TEST=1 SI_PROC=$P SI_CONF=$T/conf.json SI_DATA=$T/data-cache \
  SI_MIN_AGE=15 SI_FUSE_WAIT=1 SI_TEST_DATA=$DATA SI_TEST_SRC=$SRC \
  PATH=$BIN:$PATH "$TEST_SH" "$FIX" -q > "$T/cachebuild.out" 2>&1
clean_out "$T/cachebuild.out"
[ -s "$T/data-cache/.conf.cache" ] && ok "非 dry 扫描生成 .conf.cache" || bad "没有生成 .conf.cache"
cache_before=$(stat -c '%Y:%s:%i' "$T/data-cache/.conf.cache" 2>/dev/null)
run_fix_keep "$FIX" "$T/data-cache" "$T/cache1.out"
run_fix_keep "$FIX" "$T/data-cache" "$T/cache2.out"
cache_after=$(stat -c '%Y:%s:%i' "$T/data-cache/.conf.cache" 2>/dev/null)
diff -u "$T/cache1.out" "$T/cache2.out" > "$T/diff2.txt" 2>&1 \
  && ok "配置缓存命中时输出一致" \
  || { bad "缓存命中后输出变化："; sed -n '1,60p' "$T/diff2.txt"; }
[ "$cache_before" = "$cache_after" ] \
  && ok "缓存命中未重写 .conf.cache（$cache_after）" \
  || bad "缓存被重写：$cache_before -> $cache_after"
# 真正证明走了缓存：命中时不应再 cp 配置（stub 里 cp 会失败并留日志）
: > "$T/cp.log"
PATH=$T/failbin:$BIN:$PATH SI_TEST=1 SI_PROC=$P SI_CONF=$T/conf.json \
  SI_DATA=$T/data-cache SI_MIN_AGE=15 SI_FUSE_WAIT=1 \
  SI_TEST_DATA=$DATA SI_TEST_SRC=$SRC SI_TEST_CP_LOG=$T/cp.log \
  "$TEST_SH" "$FIX" -n -v > "$T/cache3.out" 2>&1
clean_out "$T/cache3.out"
[ ! -s "$T/cp.log" ] \
  && ok "缓存命中时没有调用 cp（证明真的读了缓存）" \
  || bad "缓存命中时仍调用 cp：$(cat "$T/cp.log")"
case "$(tail -1 "$T/cache3.out" 2>/dev/null)" in
  RESULT\ checked=*error=*) bad "缓存命中扫描出现 error：$(tail -1 "$T/cache3.out")" ;;
  RESULT\ checked=*) ok "缓存命中仍完成正常扫描" ;;
  *) bad "缓存命中没有 RESULT：$(tail -1 "$T/cache3.out")" ;;
esac

# repair 分支对照（真实执行，nsenter stub 让 mount/umount 失败）
rm -rf "$T/data-old-r" "$T/data-new-r"; mkdir -p "$T/data-old-r" "$T/data-new-r"
SI_TEST=1 SI_PROC=$P SI_CONF=$T/conf.json SI_DATA=$T/data-old-r \
  SI_MIN_AGE=15 SI_FUSE_WAIT=1 SI_TEST_DATA=$DATA SI_TEST_SRC=$SRC \
  PATH=$BIN:$PATH "$TEST_SH" "$T/old.sh" -v > "$T/old-repair.out" 2>&1
clean_out "$T/old-repair.out"
SI_TEST=1 SI_PROC=$P SI_CONF=$T/conf.json SI_DATA=$T/data-new-r \
  SI_MIN_AGE=15 SI_FUSE_WAIT=1 SI_TEST_DATA=$DATA SI_TEST_SRC=$SRC \
  PATH=$BIN:$PATH "$TEST_SH" "$FIX" -v > "$T/new-repair.out" 2>&1
clean_out "$T/new-repair.out"
if [ ! -s "$T/old-repair.out" ] || [ ! -s "$T/new-repair.out" ]; then
  bad "repair 分支两侧输出为空，拒绝判绿"
elif diff -u "$T/old-repair.out" "$T/new-repair.out" > "$T/diff-repair.txt" 2>&1; then
  ok "repair 分支输出一致（$(wc -l < "$T/new-repair.out") 行）"
else
  bad "repair 分支输出不一致："
  sed -n '1,80p' "$T/diff-repair.txt"
fi

# 空 apps 是有意修正，不是回归：1.3.4 把“零 app 的合法配置”当成 error=config
# （还会被 awk END 误报成 ps），守护据此一直显示配置损坏；1.4.0 的 si-config.awk
# 把它视为“合法但没东西可修”：checked=0，且不能出现任何 error=。
# 真机顶层字段是 packages（不是 apps），两种都支持；这里保留 apps 用例覆盖空数组。
printf '{"apps":[]}' > "$T/empty.json"
SI_TEST=1 SI_PROC=$P SI_CONF=$T/empty.json SI_DATA=$T/data-empty \
  SI_MIN_AGE=15 SI_FUSE_WAIT=1 SI_TEST_DATA=$DATA SI_TEST_SRC=$SRC \
  PATH=$BIN:$PATH "$TEST_SH" "$FIX" -n -q > "$T/empty.out" 2>&1
clean_out "$T/empty.out"
case "$(tail -1 "$T/empty.out")" in
  *error=*) bad "空 apps 不应报 error（合法配置）：$(tail -1 "$T/empty.out")" ;;
  *checked=0*) ok "空 apps 视为合法空配置：checked=0 且无 error（相对 1.3.4 的有意修正）" ;;
  *) bad "空 apps 输出不符合预期：$(tail -1 "$T/empty.out")" ;;
esac
# 顶层字段写成 packages（真机形态）时同样不该报 error
printf '{"packages":[]}' > "$T/empty-pkg.json"
SI_TEST=1 SI_PROC=$P SI_CONF=$T/empty-pkg.json SI_DATA=$T/data-empty-pkg \
  SI_MIN_AGE=15 SI_FUSE_WAIT=1 SI_TEST_DATA=$DATA SI_TEST_SRC=$SRC \
  PATH=$BIN:$PATH "$TEST_SH" "$FIX" -n -q > "$T/empty-pkg.out" 2>&1
clean_out "$T/empty-pkg.out"
case "$(tail -1 "$T/empty-pkg.out")" in
  *error=*) bad "空 packages 不应报 error：$(tail -1 "$T/empty-pkg.out")" ;;
  *checked=0*) ok "空 packages 同样视为合法空配置" ;;
  *) bad "空 packages 输出不符合预期：$(tail -1 "$T/empty-pkg.out")" ;;
esac

# 配置变更后缓存必须失效（同目录已有旧 .conf.cache）
cp "$T/conf.json" "$T/conf.orig" 2>/dev/null
sed 's/"package_name":"com.enabled","enabled":true/"package_name":"com.enabled","enabled":false/' \
  "$T/conf.orig" > "$T/conf.json"
SI_TEST=1 SI_PROC=$P SI_CONF=$T/conf.json SI_DATA=$T/data-cache \
  SI_MIN_AGE=15 SI_FUSE_WAIT=1 SI_TEST_DATA=$DATA SI_TEST_SRC=$SRC \
  PATH=$BIN:$PATH "$TEST_SH" "$FIX" -n -v > "$T/inv-new.out" 2>&1
clean_out "$T/inv-new.out"
SI_TEST=1 SI_PROC=$P SI_CONF=$T/conf.json SI_DATA=$T/data-inv-old \
  SI_MIN_AGE=15 SI_FUSE_WAIT=1 SI_TEST_DATA=$DATA SI_TEST_SRC=$SRC \
  PATH=$BIN:$PATH "$TEST_SH" "$T/old.sh" -n -v > "$T/inv-old.out" 2>&1
clean_out "$T/inv-old.out"
if diff -u "$T/inv-old.out" "$T/inv-new.out" > "$T/diff-inv.txt" 2>&1; then
  ok "配置变更后缓存失效，输出与 1.3.4 一致"
else
  bad "配置变更后缓存未失效："
  sed -n '1,50p' "$T/diff-inv.txt"
fi

# 同字节数改写（com.sub -> com.sux，长度不变）：仍必须按 mtime 失效
sed 's/"package_name":"com.sub"/"package_name":"com.sux"/' "$T/conf.json" > "$T/conf.tmp"
mv -f "$T/conf.tmp" "$T/conf.json"
SI_TEST=1 SI_PROC=$P SI_CONF=$T/conf.json SI_DATA=$T/data-cache \
  SI_MIN_AGE=15 SI_FUSE_WAIT=1 SI_TEST_DATA=$DATA SI_TEST_SRC=$SRC \
  PATH=$BIN:$PATH "$TEST_SH" "$FIX" -n -v > "$T/inv2-new.out" 2>&1
clean_out "$T/inv2-new.out"
SI_TEST=1 SI_PROC=$P SI_CONF=$T/conf.json SI_DATA=$T/data-inv2-old \
  SI_MIN_AGE=15 SI_FUSE_WAIT=1 SI_TEST_DATA=$DATA SI_TEST_SRC=$SRC \
  PATH=$BIN:$PATH "$TEST_SH" "$T/old.sh" -n -v > "$T/inv2-old.out" 2>&1
clean_out "$T/inv2-old.out"
if diff -u "$T/inv2-old.out" "$T/inv2-new.out" > "$T/diff-inv2.txt" 2>&1; then
  ok "同字节数改写也按 mtime 失效"
else
  bad "同字节数改写缓存未失效："
  sed -n '1,50p' "$T/diff-inv2.txt"
fi

echo
[ "$fail" = 0 ] && { echo "equiv.test: PASS"; exit 0; }
echo "equiv.test: FAIL"; exit 1
