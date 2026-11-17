#!/system/bin/sh
# 沙箱丢失检测与重建回归（真实 fix 脚本 + 假 /proc + ps/nsenter/mount stub）
#
# 覆盖：
#   0) 识别到合法沙箱 → 包名登记进 .sandbox_seen（去重、最多 200 行保留最近）
#   1) 正例：seen 里有、当前无沙箱、源/属主/namespace 都通过 → bind 沙箱并补
#      allow 目录与 Android/{data,media,obb}/<pkg>；RESULT fixed 增加、sandbox=1；
#      再跑一次 fixed=0（已健康）
#   2) 源缺失 → skipped=sandbox_gone，且不调用 mount
#   3) 源属主不是进程 uid → skipped=sandbox_gone，且不调用 mount
#   4) 已有沙箱 → 不触发重建（无 sandbox=、无 mount）
#   5) 从未见过沙箱 → 保持静默（不重建、不报 sandbox_gone）
#   6) dry-run → 报 skipped=sandbox_gone，但绝不调用 mount/nsenter
#   7) 同包多 PID：每个 namespace 都 bind，sandbox/fixed 只计一次
#   8) bind 后 device 校验失败 → umount 回滚并报 sandbox_gone
#   9) 旧 FUSE 僵死：沙箱设备已不在宿主 → skipped=sandbox_stale，不 mount/umount
#  10) 旧设备在宿主仍存在（只是层不同）→ 保持 skipped=layer
#  11) 应用 ns 看不到 /mnt/user/... 时，回退到应用视图 /storage/emulated/0 重建
#
# 用法：sh tools/sandbox.test.sh
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

T=${TMPDIR:-/tmp}/si-sandbox-test.$$
trap 'rm -rf "$T"' EXIT INT TERM HUP
P=$T/proc; BIN=$T/bin; DATA=$T/data; SRC=$T/mnt/user/0/emulated
MI=$P/123/mountinfo
mkdir -p "$P/self" "$P/123" "$BIN" "$DATA" "$SRC" || exit 1

# 宿主 FUSE 设备号；默认 0:50，僵死用例临时换成新设备号。
self_mi() {   # $1=FUSE 设备号
  cat > "$P/self/mountinfo" <<M
100 1 0:50 / / rw - ext4 /dev/root rw
101 100 $1 / /mnt/user/0/emulated rw - fuse /dev/fuse rw
102 100 $1 / /storage/emulated rw - fuse /dev/fuse rw
M
}
self_mi 0:50

# 进程 uid 用当前用户：源目录由测试创建，属主校验走真实 stat（负例再用 SI_TEST_UID 覆盖）。
TEST_UID=$(id -u 2>/dev/null)
case "$TEST_UID" in ''|*[!0-9]*) TEST_UID=0 ;; esac

cat > "$T/conf.json" <<'J'
{"mount_dirs_templates":[{"id":"t1","list":["DCIM"]}],"apps":[{"package_name":"com.victim","enabled":true,"mount_dirs":true,"template_ids":["t1"]}]}
J

cat > "$BIN/ps" <<S
#!/bin/sh
echo "  PID   UID     ELAPSED ARGS"
echo "  123     $TEST_UID    10:00 com.victim"
[ "\$SI_TEST_PS_EXTRA" = 1 ] && echo "  124     $TEST_UID    10:00 com.victim"
S
# nsenter stub：记录调用；test -d 由“应用 namespace”回答；mount/umount 交给同名 stub
# （它们会改 fake mountinfo，模拟真实 bind/umount 的结果）。
cat > "$BIN/nsenter" <<'S'
#!/bin/sh
pid=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -t) pid=$2; shift 2 ;;
    -m|--) shift ;;
    *) break ;;
  esac
done
[ -n "$pid" ] && [ -n "$SI_TEST_NSENTER_LOG" ] && echo "pid=$pid $*" >> "$SI_TEST_NSENTER_LOG"
export SI_TEST_PID=$pid
case "$1" in
  test)
    shift
    [ "$1" = "-d" ] && shift
    # 模拟“应用 ns 看不到这个源”：只命中测试指定的路径。
    if [ -n "$SI_TEST_NS_HIDE" ] && [ "${1:-}" = "$SI_TEST_NS_HIDE" ]; then exit 1; fi
    exit 0 ;;
  mount|umount) exec "$@" ;;
esac
exit 1
S
# mount stub：--bind 时把沙箱行 append 到 fake mountinfo，让 bind 后校验通过。
cat > "$BIN/mount" <<'S'
#!/bin/sh
[ -n "$SI_TEST_MOUNT_LOG" ] && echo "$*" >> "$SI_TEST_MOUNT_LOG"
[ "$1" = "--bind" ] || exit 1
src=$2; tgt=$3
mi=$SI_TEST_MI
[ -n "$SI_TEST_MI_DIR" ] && [ -n "$SI_TEST_PID" ] && mi=$SI_TEST_MI_DIR/$SI_TEST_PID/mountinfo
[ -n "$mi" ] || exit 1
dev=${SI_TEST_FDEV:-0:50}
[ "$SI_TEST_BIND_BAD" = 1 ] && dev=0:99
printf '300 1 %s %s %s rw - fuse /dev/fuse rw\n' "$dev" "$src" "$tgt" >> "$mi"
S
# umount stub：按 target 删除 fake mountinfo 里的行（绑定失败回滚用）。
cat > "$BIN/umount" <<'S'
#!/bin/sh
[ -n "$SI_TEST_UMOUNT_LOG" ] && echo "$*" >> "$SI_TEST_UMOUNT_LOG"
[ "$1" = "-l" ] && shift
tgt=${1:-}
[ -n "$tgt" ] || exit 1
mi=$SI_TEST_MI
[ -n "$SI_TEST_MI_DIR" ] && [ -n "$SI_TEST_PID" ] && mi=$SI_TEST_MI_DIR/$SI_TEST_PID/mountinfo
[ -n "$mi" ] || exit 1
awk -v t="$tgt" '$5 != t' "$mi" > "$mi.tmp" 2>/dev/null && mv -f "$mi.tmp" "$mi" 2>/dev/null
S
chmod 755 "$BIN/ps" "$BIN/nsenter" "$BIN/mount" "$BIN/umount"

# 无沙箱的宿主 FUSE 视图（沙箱挂载已被 vold 的 FUSE 重挂带走）。
base_mi() {
  cat > "$MI" <<'M'
101 100 0:50 / /mnt/user/0/emulated rw - fuse /dev/fuse rw
102 100 0:50 / /storage/emulated rw - fuse /dev/fuse rw
M
}
base_mi2() {
  base_mi
  cat > "$P/124/mountinfo" <<'M'
101 100 0:50 / /mnt/user/0/emulated rw - fuse /dev/fuse rw
102 100 0:50 / /storage/emulated rw - fuse /dev/fuse rw
M
}
# 正常隔离的应用：沙箱根 + allow 目录 + Android 目录都在。
healthy_mi() {
  cat > "$MI" <<'M'
101 100 0:50 / /mnt/user/0/emulated rw - fuse /dev/fuse rw
102 100 0:50 / /storage/emulated rw - fuse /dev/fuse rw
200 1 0:50 /0/Android/data/com.victim/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
201 200 0:50 /0/DCIM /storage/emulated/0/DCIM rw - fuse /dev/fuse rw
202 200 0:50 /0/Android/data/com.victim /storage/emulated/0/Android/data/com.victim rw - fuse /dev/fuse rw
203 200 0:50 /0/Android/media/com.victim /storage/emulated/0/Android/media/com.victim rw - fuse /dev/fuse rw
204 200 0:50 /0/Android/obb/com.victim /storage/emulated/0/Android/obb/com.victim rw - fuse /dev/fuse rw
M
}
# 假源目录：沙箱根（含 allow/Android 子目录）与 FUSE 共享层、/data 物理层。
setup_src() {
  rm -rf "$SRC/0/Android/data/com.victim"
  mkdir -p "$SRC/0/Android/data/com.victim/sdcard/Android/data" \
           "$SRC/0/Android/data/com.victim/sdcard/Android/media" \
           "$SRC/0/Android/data/com.victim/sdcard/Android/obb" \
           "$SRC/0/Android/data/com.victim/sdcard/DCIM" \
           "$SRC/0/DCIM" \
           "$SRC/0/Android/data/com.victim" \
           "$SRC/0/Android/media/com.victim" \
           "$SRC/0/Android/obb/com.victim" \
           "$DATA/media/0/Android/data/com.victim" \
           "$DATA/media/0/Android/media/com.victim" \
           "$DATA/media/0/Android/obb/com.victim" || return 1
}

UID_OVERRIDE=""; MI_DIR_OVERRIDE=""; PS_EXTRA=0; BIND_BAD=0
ALT_ROOT=""; NS_HIDE=""
run_fix() {   # $1=数据目录 $2=1 表示 dry-run
  _d=$1; _dry=$2
  rm -f "$T/mount.log" "$T/nsenter.log" "$T/umount.log"
  set -- env PATH="$BIN:$PATH" \
    SI_TEST=1 SI_PROC="$P" SI_CONF="$T/conf.json" SI_DATA="$_d" \
    SI_TEST_DATA="$DATA" SI_TEST_SRC="$SRC" SI_TEST_ALT="$ALT_ROOT" SI_MIN_AGE=5 \
    SI_TEST_FDEV=0:50 SI_TEST_MI="$MI" SI_TEST_MI_DIR="$MI_DIR_OVERRIDE" \
    SI_TEST_UID="$UID_OVERRIDE" SI_TEST_PS_EXTRA="$PS_EXTRA" SI_TEST_BIND_BAD="$BIND_BAD" \
    SI_TEST_NS_HIDE="$NS_HIDE" \
    SI_TEST_MOUNT_LOG="$T/mount.log" SI_TEST_NSENTER_LOG="$T/nsenter.log" \
    SI_TEST_UMOUNT_LOG="$T/umount.log" \
    "$TEST_SH" "$FIX"
  [ "$_dry" = 1 ] && set -- "$@" -n
  "$@" 2>&1
}
seed_seen() {   # $1=数据目录；写一个含 com.victim 的 .sandbox_seen
  mkdir -p "$1" || return 1
  printf 'com.victim\n' > "$1/.sandbox_seen"
}
result() { printf '%s\n' "$1" | sed -n 's/^RESULT //p' | tail -1; }
num() {      # $1=RESULT 行 $2=字段名 -> 数字（缺失为空）
  printf '%s\n' "$1" | sed -n "s/.* $2=\([0-9][0-9]*\).*/\1/p" | tail -1
}
has() {      # $1=输出 $2=要查找的子串
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  return 1
}

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }

# ---------- 0) K → .sandbox_seen 登记、去重、200 行上限 ----------
D0=$T/data0; rm -rf "$D0"; mkdir -p "$D0"
i=1
while [ "$i" -le 205 ]; do echo "com.old$i"; i=$((i + 1)); done > "$D0/.sandbox_seen"
healthy_mi
out=$(run_fix "$D0" 1); r=$(result "$out")
grep -qxF 'com.victim' "$D0/.sandbox_seen" 2>/dev/null \
  && ok "识别到合法沙箱后登记 .sandbox_seen" \
  || bad "合法沙箱没有登记：$(head -3 "$D0/.sandbox_seen" 2>/dev/null)"
n=$(wc -l < "$D0/.sandbox_seen" 2>/dev/null)
[ "${n:-0}" -le 200 ] && ok "登记后仍限制在 200 行（$n）" || bad "登记后 $n 行（超过 200）"
out=$(run_fix "$D0" 1); r=$(result "$out")
n=$(wc -l < "$D0/.sandbox_seen" 2>/dev/null)
c=$(grep -cxF 'com.victim' "$D0/.sandbox_seen" 2>/dev/null)
[ "${n:-0}" -le 200 ] && [ "$c" = 1 ] \
  && ok "重复扫描不重复登记（仍 $n 行，com.victim 一次）" \
  || bad "重复登记：$n 行，com.victim $c 次"

# ---------- 1) 正例：重建沙箱 + allow/Android 目录 ----------
D1=$T/data1; seed_seen "$D1" || exit 1
base_mi; setup_src || exit 1
out=$(run_fix "$D1" 0); r=$(result "$out")
f=$(num "$r" fixed)
[ "${f:-0}" -ge 2 ] && ok "重建后 fixed>=2（沙箱+目录，实际 $f）" || bad "fixed 不足：$r"
has "$r" 'sandbox=1' && ok "RESULT 带 sandbox=1" || bad "RESULT 没有 sandbox=1：$r"
has "$r" 'broken=1' && ok "重建成功的进程计入 broken=1" || bad "broken 不是 1：$r"
printf '%s\n' "$out" | grep -q '重建沙箱: com.victim (pid 123)' \
  && ok "日志写重建行" || bad "缺少重建日志：$out"
grep -q '/Android/data/com.victim/sdcard /storage/emulated/0 ' "$MI" 2>/dev/null \
  && ok "fake mountinfo 出现沙箱 bind（source/target 正确）" \
  || bad "沙箱 bind 没有落到 target：$(cat "$MI" 2>/dev/null)"
grep -q ' /storage/emulated/0/DCIM ' "$MI" 2>/dev/null \
  && ok "allow 目录 DCIM 已补挂" || bad "DCIM 没有补挂"
grep -q ' /storage/emulated/0/Android/data/com.victim ' "$MI" 2>/dev/null \
  && ok "Android/data/<pkg> 已补挂" || bad "Android/data 没有补挂"
out=$(run_fix "$D1" 0); r=$(result "$out")
f=$(num "$r" fixed)
[ "${f:-0}" = 0 ] && ok "再跑一次 fixed=0（已健康）" || bad "健康后仍修复：$r"
has "$r" 'sandbox=' && bad "健康后仍报 sandbox：$r" || ok "健康后不再报 sandbox"
[ ! -s "$T/mount.log" ] && ok "健康后没有调用 mount" || bad "健康后仍调用 mount：$(cat "$T/mount.log")"

# ---------- 2) 源缺失 ----------
D2=$T/data2; seed_seen "$D2" || exit 1
base_mi; setup_src || exit 1
rm -rf "$SRC/0/Android/data/com.victim/sdcard"
out=$(run_fix "$D2" 0); r=$(result "$out")
has "$r" 'sandbox_gone' && ok "源缺失报 skipped=sandbox_gone" || bad "源缺失没有报：$r"
has "$r" 'fixed=0' && ok "源缺失时 fixed=0" || bad "源缺失仍计 fixed：$r"
[ ! -s "$T/mount.log" ] && ok "源缺失时没有调用 mount" || bad "源缺失仍 mount：$(cat "$T/mount.log")"

# ---------- 3) 属主不符 ----------
D3=$T/data3; seed_seen "$D3" || exit 1
base_mi; setup_src || exit 1
UID_OVERRIDE=123456
out=$(run_fix "$D3" 0); r=$(result "$out")
UID_OVERRIDE=""
has "$r" 'sandbox_gone' && ok "属主不符报 skipped=sandbox_gone" || bad "属主不符没有报：$r"
has "$out" '属主' && ok "日志说明属主不符" || bad "日志没有属主原因：$out"
[ ! -s "$T/mount.log" ] && ok "属主不符时没有调用 mount" || bad "属主不符仍 mount：$(cat "$T/mount.log")"

# ---------- 4) 已经沙箱 ----------
D4=$T/data4; seed_seen "$D4" || exit 1
healthy_mi
out=$(run_fix "$D4" 0); r=$(result "$out")
has "$r" 'fixed=0' && ok "已有沙箱时 fixed=0" || bad "已有沙箱仍修复：$r"
has "$r" 'sandbox=' && bad "已有沙箱仍报 sandbox：$r" || ok "已有沙箱不报 sandbox（未触发 G）"
[ ! -s "$T/mount.log" ] && ok "已有沙箱时没有调用 mount" || bad "已有沙箱仍 mount：$(cat "$T/mount.log")"

# ---------- 5) 从未见过沙箱 ----------
D5=$T/data5; mkdir -p "$D5" || exit 1
: > "$D5/.sandbox_seen"
base_mi
out=$(run_fix "$D5" 0); r=$(result "$out")
has "$r" 'sandbox_gone' && bad "从未见过沙箱却报 sandbox_gone：$r" \
  || ok "从未见过沙箱保持静默（无 sandbox_gone）"
has "$r" 'checked=1' && ok "无沙箱进程仍被扫描（checked=1）" || bad "没有扫描到进程：$r"
[ ! -s "$T/mount.log" ] && ok "从未见过沙箱时没有调用 mount" || bad "静默跳过仍 mount：$(cat "$T/mount.log")"
[ ! -s "$D5/.sandbox_seen" ] && ok "没有沙箱证据时 .sandbox_seen 保持为空" \
  || bad ".sandbox_seen 被写入：$(cat "$D5/.sandbox_seen" 2>/dev/null)"

# ---------- 6) dry-run 只报告，绝不 bind ----------
D6=$T/data6; seed_seen "$D6" || exit 1
base_mi; setup_src || exit 1
out=$(run_fix "$D6" 1); r=$(result "$out")
has "$r" 'sandbox_gone' && ok "dry-run 报 skipped=sandbox_gone" || bad "dry-run 没有报：$r"
has "$r" 'sandbox=' && bad "dry-run 竟报 sandbox：$r" || ok "dry-run 不报 sandbox"
has "$r" 'broken=1' && ok "dry-run 仍指出需要重建（broken=1）" || bad "dry-run broken 不是 1：$r"
[ ! -s "$T/mount.log" ] && ok "dry-run 没有调用 mount" || bad "dry-run 调用了 mount：$(cat "$T/mount.log")"
[ ! -s "$T/nsenter.log" ] && ok "dry-run 没有调用 nsenter" || bad "dry-run 调用了 nsenter：$(cat "$T/nsenter.log")"
[ ! -e "$D6/.repairs" ] && ok "dry-run 不写 .repairs" || bad "dry-run 写了 .repairs"

# ---------- 7) 同包多 PID：每个 namespace 都 bind，计数只一次 ----------
D7=$T/data7; seed_seen "$D7" || exit 1
mkdir -p "$P/124" || exit 1
base_mi2; setup_src || exit 1
MI_DIR_OVERRIDE=$P; PS_EXTRA=1
out=$(run_fix "$D7" 0); r=$(result "$out")
MI_DIR_OVERRIDE=""; PS_EXTRA=0
has "$r" 'sandbox=1' && ok "同包 2 个 PID 只计 sandbox=1" || bad "sandbox 计数不对：$r"
has "$r" 'broken=2' && ok "2 个 PID 都算需要修复（broken=2）" || bad "broken 不是 2：$r"
grep -q '/Android/data/com.victim/sdcard /storage/emulated/0 ' "$P/123/mountinfo" 2>/dev/null \
  && grep -q '/Android/data/com.victim/sdcard /storage/emulated/0 ' "$P/124/mountinfo" 2>/dev/null \
  && ok "两个 PID 的 namespace 都补上了沙箱" || bad "有 PID 没补上沙箱"
f=$(num "$r" fixed)
[ "${f:-0}" -ge 2 ] && [ "${f:-0}" -le 5 ] \
  && ok "多 PID 的 fixed 去重计数（$f）" || bad "多 PID fixed 计数异常：$r"
rm -rf "$P/124"

# ---------- 8) bind 后校验失败：umount 回滚 ----------
D8=$T/data8; seed_seen "$D8" || exit 1
base_mi; setup_src || exit 1
BIND_BAD=1
out=$(run_fix "$D8" 0); r=$(result "$out")
BIND_BAD=0
has "$r" 'sandbox_gone' && ok "校验失败报 skipped=sandbox_gone" || bad "校验失败没有报：$r"
has "$r" 'fixed=0' && ok "校验失败不计 fixed" || bad "校验失败仍计 fixed：$r"
has "$out" '校验失败' && ok "日志说明校验失败并回滚" || bad "日志没有校验失败原因：$out"
grep -q ' /storage/emulated/0 ' "$MI" 2>/dev/null \
  && bad "校验失败后沙箱行没有回滚：$(cat "$MI")" \
  || ok "校验失败后已 umount 回滚"

# ---------- 9) 旧 FUSE 僵死：ST 行只提示，不 mount/umount ----------
stale_app_mi() {
  cat > "$MI" <<'M'
101 100 0:286 / /mnt/user/0/emulated rw - fuse /dev/fuse rw
102 100 0:286 / /storage/emulated rw - fuse /dev/fuse rw
200 1 0:286 /0/Android/data/com.victim/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
201 200 0:286 /0/DCIM /storage/emulated/0/DCIM rw - fuse /dev/fuse rw
M
}
D9=$T/data9; seed_seen "$D9" || exit 1
self_mi 0:318; stale_app_mi
out=$(run_fix "$D9" 0); r=$(result "$out")
has "$r" 'sandbox_stale' && ok "旧 FUSE 设备不在宿主 → skipped=sandbox_stale" || bad "没有识别僵死：$r"
has "$r" 'sandbox_gone' && bad "僵死被误报为可重建的 sandbox_gone：$r" || ok "僵死不报 sandbox_gone"
has "$r" 'fixed=0' && ok "僵死不产生修复计数" || bad "僵死仍计 fixed：$r"
has "$out" '需要重启应用' && ok "日志提示需要重启应用" || bad "日志没有提示重启：$out"
[ ! -s "$T/mount.log" ] && ok "僵死时没有调用 mount" || bad "僵死仍 mount：$(cat "$T/mount.log")"
[ ! -s "$T/umount.log" ] && ok "僵死时没有调用 umount" || bad "僵死仍 umount：$(cat "$T/umount.log")"
[ ! -s "$T/nsenter.log" ] && ok "僵死时没有调用 nsenter" || bad "僵死仍 nsenter：$(cat "$T/nsenter.log")"

# ---------- 10) 旧设备在宿主仍存在：保持 layer，不误判僵死 ----------
D10=$T/data10; seed_seen "$D10" || exit 1
self_mi 0:318
printf '103 100 0:286 / /mnt/old-fuse rw - fuse /dev/fuse rw\n' >> "$P/self/mountinfo"
stale_app_mi
out=$(run_fix "$D10" 0); r=$(result "$out")
has "$r" 'skipped=layer' && ok "宿主仍存在该设备时保持 skipped=layer" || bad "没有保持 layer：$r"
has "$r" 'sandbox_stale' && bad "真正的 layer 被误判成僵死：$r" || ok "layer 不误报 sandbox_stale"
has "$r" 'fixed=0' && ok "layer 不产生修复计数" || bad "layer 仍计 fixed：$r"
    [ ! -s "$T/mount.log" ] && [ ! -s "$T/umount.log" ] && ok "layer 时没有 mount/umount" || bad "layer 仍动挂载"
self_mi 0:50

# ---------- 11) 源回退：应用 ns 看不到 /mnt/user/... ----------
D11=$T/data11; seed_seen "$D11" || exit 1
self_mi 0:50; base_mi; setup_src || exit 1
ALT=$T/alt0; rm -rf "$ALT"
mkdir -p "$ALT/Android/data/com.victim/sdcard/Android/data" \
         "$ALT/Android/data/com.victim/sdcard/Android/media" \
         "$ALT/Android/data/com.victim/sdcard/Android/obb" \
         "$ALT/Android/data/com.victim/sdcard/DCIM" || exit 1
ALT_ROOT=$ALT; NS_HIDE=$SRC/0/Android/data/com.victim/sdcard
out=$(run_fix "$D11" 0); r=$(result "$out")
ALT_ROOT=""; NS_HIDE=""
has "$r" 'sandbox=1' && ok "宿主源在应用 ns 不可见时仍能重建（sandbox=1）" || bad "回退重建失败：$r"
f=$(num "$r" fixed)
[ "${f:-0}" -ge 2 ] && ok "回退重建后 fixed>=2（实际 $f）" || bad "回退后 fixed 不足：$r"
has "$out" '沙箱源改用应用视图' && ok "日志说明使用了应用视图源" || bad "日志没有回退说明：$out"
grep -qF -- "--bind $ALT/Android/data/com.victim/sdcard /storage/emulated/0" "$T/mount.log" 2>/dev/null \
  && ok "bind 使用的是 /storage/emulated/0 应用视图源" \
  || bad "没有用回退源 bind：$(cat "$T/mount.log" 2>/dev/null)"
grep -qF -- "--bind $SRC/0/Android/data/com.victim/sdcard /storage/emulated/0" "$T/mount.log" 2>/dev/null \
  && bad "仍在用应用 ns 看不到的宿主源" \
  || ok "没有使用应用 ns 看不到的宿主源"
grep -qF "$ALT/Android/data/com.victim/sdcard /storage/emulated/0" "$MI" 2>/dev/null \
  && ok "fake mountinfo 记录了回退源" || bad "fake mountinfo 没有回退源：$(cat "$MI" 2>/dev/null)"

echo
[ "$fail" = 0 ] && { echo "sandbox.test: PASS"; exit 0; }
echo "sandbox.test: FAIL"; exit 1
