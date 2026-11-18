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
#  25) init /storage 旧、/mnt 新：按 /mnt 基准判 stale（不能被 /storage 带偏）
#  26) 旧格式 seen 行被忽略，已丢沙箱仍能凭源+属主重建
#  27) 无 SB 且 pkg/shared 两个变体都在 → fail-closed，不 bind
#  28) 沙箱 umount 失败：不把原 FUSE 根叠回去，打 rollback tag 并保留现状
#  29) 普通 FUSE 根被临时卸下后，bind 校验失败会把它挂回去
#  30~34) 普通根 root=/0、共享源缺失/bindfail/不可读回滚、双变体歧义
#  35) R3 主扫描校验 target 栈顶/层数：叠层 → rollback、不登记 K
#  36) R3 残留非本包沙箱：阻止 K、按 stale 上报
#  37) R4 无同 ns 证据 + 普通根：不卸不 bind，报 sandbox_skip
#  38) E-P1 同 boot 异 ns：n=0 回落重建；普通根仍 sandbox_skip
#  39) K 的空 namespace 不落盘
#  40) R2 沙箱失败退避：时间到期/换 ns 才重试
#  41) R2 repair_one 退避：source/bindfail 不每轮重试
#  42) 锁目录建不出来：error=datadir（不能静默 exit 0）
#  43) 普通根 umount 未生效：报“umount 未生效”，不谎报已卸下、不 bind
#  44) bind 后 n>1：与主扫描一致，不计 fixed、报 rollback/stale
#  45) 沙箱卸了但原根恢复失败：报 stale、不打“已回滚”
#  46) .sandbox_seen 里的空 ns 行被过滤，不再当证据
#  47) 窗口里 SI 挂回普通根：第二道守卫仍拒绝（不拆不 bind）
#  48) P1 混合 seen（本 boot 旧 ns + 旧 boot）n=0：允许回落重建
#  49) P2 目标被别层占用：报 sandbox_skip（需重启应用），不报 gone/不重试
#  50) 子进程 pkg:push 单独 ns：按基础包名查配置，两个 ns 都重建
#  51) custom_dirs 含 sandbox + 沙箱失败：目录失败行不撞沙箱退避键
#  51b) 合法目录 @sandbox 与内部 /@sandbox 键互不干扰
#  51c) 旧 #SI2 缓存失效，不再 bind 缓存里的 @sandbox
#  51d) 反例：当前 #SI3 缓存确实会 bind，证明 51c 不是 grep 假绿
#  52) dry-run 不清理/不改写已有 old-format .sandbox_seen
#  53) 没有 mount_dirs 的 app（Q 有 P 无）不计入 checked
#  54) 退避只看单调时钟：系统时间跳变不改变退避
#  55) 旧格式（只有墙钟）的失败行不参与退避
#  56) custom_dirs 里的 * 是字面量（不展开 glob），含 * 的目录照样补挂
#  57) 锚点目录缺失：主扫描报 target_missing + broken，不 bind
#  58) 锚点目录缺失：重建循环报 target_missing，沙箱仍然重建
#  59) 普通根 root=/0：回滚按原 root 挂回并校验
#  60) 普通根 root=/0：恢复后 root 不符 → rollback，不谎报已挂回
#  61) 普通根 root=/0：umount 未生效 → 不 restore
#  62) 扫描后进程变化（重建路径）：不 bind/umount，报 pid_changed
#  63) 扫描后进程变化（T 路径）：不 bind/umount，报 pid_changed
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
# zzg 是 * 字面量用例故意放在当前目录的干扰文件，防止中断后留在仓库里。
trap 'rm -rf "$T"; rm -f zzg' EXIT INT TERM HUP
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
mkdir -p "$P/1" || exit 1
host_mi() {   # $1=FUSE 设备号（写 init 的 mount namespace 基准）
  cat > "$P/1/mountinfo" <<M
100 1 0:50 / / rw - ext4 /dev/root rw
101 100 $1 / /mnt/user/0/emulated rw - fuse /dev/fuse rw
102 100 $1 / /storage/emulated rw - fuse /dev/fuse rw
M
}

# 进程 uid 用当前用户：源目录由测试创建，属主校验走真实 stat（负例再用 SI_TEST_UID 覆盖）。
TEST_UID=$(id -u 2>/dev/null)
case "$TEST_UID" in ''|*[!0-9]*) TEST_UID=0 ;; esac
TEST_BOOT=testboot
TEST_NS='mnt:[4026532001]'
mkdir -p "$P/123/ns" || exit 1
ln -sf "$TEST_NS" "$P/123/ns/mnt"
# 每个可能被修复的 pid 都要有 /proc/pid/stat（第 22 字段 starttime）与
# /proc/pid/status（Uid）；动手前的 pid_check 拿它们和扫描时的值比对，缺失按已变化处理。
mkstatline() {   # $1=pid $2=starttime
  _i=0; _f=""
  while [ "$_i" -lt 18 ]; do _f="$_f 0"; _i=$((_i + 1)); done
  printf '%s (com.victim) S%s %s\n' "$1" "$_f" "$2"
}
mkstatus() {   # $1=pid
  printf 'Name:\tcom.victim\nUid:\t%s\t%s\t%s\t%s\n' "$TEST_UID" "$TEST_UID" "$TEST_UID" "$TEST_UID" \
    > "$P/$1/status"
}
mkproc() {   # $1=pid $2=starttime
  mkstatline "$1" "$2" > "$P/$1/stat"
  mkstatus "$1"
}
mkproc 123 1000

cat > "$T/conf.json" <<'J'
{"mount_dirs_templates":[{"id":"t1","list":["DCIM"]}],"apps":[{"package_name":"com.victim","enabled":true,"mount_dirs":true,"template_ids":["t1"]},{"package_name":"shared-com.shared","enabled":true,"mount_dirs":true,"template_ids":["t1"]},{"package_name":"com.good","enabled":true,"mount_dirs":true,"template_ids":["t1"]}]}
J

cat > "$BIN/ps" <<S
#!/bin/sh
echo "  PID   UID     ELAPSED ARGS"
if [ "\$SI_TEST_PS_TWO" = 1 ]; then
  echo "  122     $TEST_UID    10:00 com.good"
  echo "  123     $TEST_UID    10:00 com.victim"
  exit 0
fi
if [ "\$SI_TEST_PS_NODIRS" = 1 ]; then
  echo "  123     $TEST_UID    10:00 com.victim"
  echo "  125     $TEST_UID    10:00 com.nodirs"
  exit 0
fi
if [ "\$SI_TEST_PS_SUB" = 1 ]; then
  echo "  123     $TEST_UID    10:00 com.victim"
  echo "  124     $TEST_UID    10:00 com.victim:push"
  exit 0
fi
echo "  123     $TEST_UID    10:00 \${SI_TEST_PS_PKG:-com.victim}"
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
    _op=""
    case "$1" in -d|-r) _op=$1; shift ;; esac
    _p=${1:-}
    # 模拟“应用 ns 看不到这个源”：精确路径或整棵前缀。
    [ -n "$SI_TEST_NS_HIDE" ] && [ "$_p" = "$SI_TEST_NS_HIDE" ] && exit 1
    if [ -n "$SI_TEST_NS_HIDE_PREFIX" ]; then
      case "$_p" in "$SI_TEST_NS_HIDE_PREFIX"*) exit 1 ;; esac
    fi
    if [ "$SI_TEST_NS_TARGET_UNREADABLE" = 1 ] && [ "$_op" = "-r" ] && [ "$_p" = "/storage/emulated/0" ]; then exit 1; fi
    # 模拟“扫描之后、动手之前进程被重启”：命中指定路径时改写 pid 的 stat（starttime）。
    if [ -n "$SI_TEST_STAT_FLIP" ] && [ "$_op" = "-d" ] && [ "$_p" = "$SI_TEST_STAT_FLIP" ] \
       && [ -n "$SI_TEST_STAT_FILE" ] && [ -n "$SI_TEST_STAT_CHANGED" ]; then
      cp -f "$SI_TEST_STAT_CHANGED" "$SI_TEST_STAT_FILE" 2>/dev/null
    fi
    # 模拟 SI 在“资格检查→拆根”的窗口里把普通 FUSE 根挂回来（测第二道守卫）。
    if [ "$SI_TEST_NS_PLANT_ROOT" = 1 ] && [ "$_op" = "-d" ] && [ -n "$SI_TEST_MI" ]; then
      grep -q ' / /storage/emulated/0 ' "$SI_TEST_MI" 2>/dev/null \
        || printf '103 100 0:50 / /storage/emulated/0 rw - fuse /dev/fuse rw\n' >> "$SI_TEST_MI"
    fi
    exit 0 ;;
  stat) echo "${SI_TEST_UID:-${SI_TEST_APP_UID:-0}}"; exit 0 ;;
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
# 只改沙箱 bind 的源；恢复普通根用的 /storage/emulated 不能被改。
if [ "$SI_TEST_BIND_WRONG_SRC" = 1 ]; then
  case "$src" in */Android/data/*) src=/0/Android/data/com.other/sdcard ;; esac
fi
[ -n "$SI_TEST_BIND_FAIL_TGT" ] && [ "$SI_TEST_BIND_FAIL_TGT" = "$tgt" ] && { echo "mount: simulated failure" >&2; exit 1; }
[ "$SI_TEST_RESTORE_FAIL" = 1 ] && [ "$src" = "/storage/emulated" ] && { echo "mount: restore failure" >&2; exit 1; }
# mountinfo 的 root 是源在其所在文件系统里的相对路径，不是宿主机绝对路径。
case "$src" in
  */mnt/user/0/emulated/*) root=/${src#*/mnt/user/0/emulated/} ;;
  /mnt/user/0/emulated) root=/ ;;
  /storage/emulated) root=/ ;;
  */storage/emulated/*) root=/${src#*/storage/emulated/} ;;
  *) root=$src ;;
esac
# 模拟“恢复普通根时挂上来的 root 和原 root 不一致”（恢复后必须校验 root）。
if [ "$SI_TEST_RESTORE_BAD_ROOT" = 1 ]; then
  case "$src" in
    "$SI_TEST_SRC/0"|/storage/emulated|"$tgt") root=/9 ;;
  esac
fi
printf '300 1 %s %s %s rw - fuse /dev/fuse rw\n' "$dev" "$root" "$tgt" >> "$mi"
# 并发挂载：同 target 再叠一条，模拟 SI 同时 bind。
[ "$SI_TEST_BIND_EXTRA" = 1 ] && printf '301 1 %s %s %s rw - fuse /dev/fuse rw\n' "$dev" "$root" "$tgt" >> "$mi"
S
# umount stub：按 target 只摘栈顶一行（真实 umount 不会一次删掉同 target 的所有层）。
# SI_TEST_UMOUNT_FAIL=1 全失败；=2 只让沙箱层失败（模拟“原根卸掉了、沙箱 busy”）。
cat > "$BIN/umount" <<'S'
#!/bin/sh
[ -n "$SI_TEST_UMOUNT_LOG" ] && echo "$*" >> "$SI_TEST_UMOUNT_LOG"
[ "$SI_TEST_UMOUNT_FAIL" = 1 ] && exit 1
[ "$1" = "-l" ] && shift
tgt=${1:-}
[ -n "$tgt" ] || exit 1
mi=$SI_TEST_MI
[ -n "$SI_TEST_MI_DIR" ] && [ -n "$SI_TEST_PID" ] && mi=$SI_TEST_MI_DIR/$SI_TEST_PID/mountinfo
[ -n "$mi" ] || exit 1
if [ "$SI_TEST_UMOUNT_FAIL" = 2 ]; then
  top=$(awk -v t="$tgt" '$5 == t { r = $4 } END { print r }' "$mi" 2>/dev/null)
  case "$top" in */Android/data/*) exit 1 ;; esac
fi
if [ "$SI_TEST_UMOUNT_FAIL" = 3 ]; then
  top=$(awk -v t="$tgt" '$5 == t { r = $4 } END { print r }' "$mi" 2>/dev/null)
  case "$top" in /|/0) exit 1 ;; esac
fi
awk -v t="$tgt" '
  { line[NR] = $0; if ($5 == t) last = NR }
  END { for (i = 1; i <= NR; i++) if (i != last) print line[i] }
' "$mi" > "$mi.tmp" 2>/dev/null && mv -f "$mi.tmp" "$mi" 2>/dev/null
S
# mkdir stub：只给“锁目录建不出来”用例用；平时原样转发（真机/测试都用系统 mkdir）。
REAL_MKDIR=$(command -v mkdir 2>/dev/null)
[ -n "$REAL_MKDIR" ] || REAL_MKDIR=/bin/mkdir
cat > "$BIN/mkdir" <<S
#!/bin/sh
if [ -n "\$SI_TEST_MKDIR_FAIL_LOCK" ]; then
  case " \$* " in
    *" \$SI_TEST_MKDIR_FAIL_LOCK "*)
      n=\$(cat "\$SI_TEST_MKDIR_COUNT" 2>/dev/null)
      case "\$n" in ''|*[!0-9]*) n=0 ;; esac
      n=\$((n + 1)); echo "\$n" > "\$SI_TEST_MKDIR_COUNT"
      [ "\$n" -ge 2 ] && exit 1
      ;;
  esac
fi
exec "$REAL_MKDIR" "\$@"
S
chmod 755 "$BIN/mkdir"
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
# 正常沙箱根 + Android 目录，但缺 DCIM 共享目录（用于 repair_one 退避）。
sandbox_ok_mi() {
  cat > "$MI" <<'M'
101 100 0:50 / /mnt/user/0/emulated rw - fuse /dev/fuse rw
102 100 0:50 / /storage/emulated rw - fuse /dev/fuse rw
200 1 0:50 /0/Android/data/com.victim/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
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
NS_HIDE=""; NS_HIDE_PREFIX=""; NS_TARGET_UNREADABLE=0
PS_PKG=""; PS_TWO=0; BIND_WRONG_SRC=0; UMOUNT_FAIL=0; BIND_FAIL_TGT=""; RUN_FIX=$FIX; TEST_NOW=""
MKDIR_FAIL_LOCK=""; MKDIR_COUNT=""; BIND_EXTRA=0; RESTORE_FAIL=0; PLANT_ROOT=0
CONF_FILE=$T/conf.json; PS_SUB=0; PS_NODIRS=0
TEST_MONO=""; RESTORE_BAD_ROOT=0; STAT_FLIP=""; STAT_FILE=""
run_fix() {   # $1=数据目录 $2=1 表示 dry-run
  _d=$1; _dry=$2
  rm -f "$T/mount.log" "$T/nsenter.log" "$T/umount.log"
  set -- env PATH="$BIN:$PATH" \
    SI_TEST=1 SI_PROC="$P" SI_CONF="$CONF_FILE" SI_DATA="$_d" \
    SI_TEST_DATA="$DATA" SI_TEST_SRC="$SRC" SI_MIN_AGE=5 \
    SI_TEST_FDEV=0:50 SI_TEST_MI="$MI" SI_TEST_MI_DIR="$MI_DIR_OVERRIDE" \
    SI_TEST_UID="$UID_OVERRIDE" SI_TEST_PS_EXTRA="$PS_EXTRA" SI_TEST_PS_PKG="$PS_PKG" SI_TEST_PS_TWO="$PS_TWO" SI_TEST_PS_SUB="$PS_SUB" SI_TEST_PS_NODIRS="$PS_NODIRS" \
    SI_TEST_BIND_BAD="$BIND_BAD" SI_TEST_BIND_WRONG_SRC="$BIND_WRONG_SRC" SI_TEST_BIND_FAIL_TGT="$BIND_FAIL_TGT" \
    SI_TEST_NS_HIDE="$NS_HIDE" SI_TEST_NS_HIDE_PREFIX="$NS_HIDE_PREFIX" SI_TEST_UMOUNT_FAIL="$UMOUNT_FAIL" \
    SI_TEST_NS_TARGET_UNREADABLE="$NS_TARGET_UNREADABLE" \
    SI_TEST_APP_UID="$TEST_UID" SI_TEST_BOOT="$TEST_BOOT" SI_TEST_NOW="$TEST_NOW" SI_TEST_MONO="$TEST_MONO" \
    SI_TEST_MOUNT_LOG="$T/mount.log" SI_TEST_NSENTER_LOG="$T/nsenter.log" \
    SI_TEST_UMOUNT_LOG="$T/umount.log" \
    SI_TEST_MKDIR_FAIL_LOCK="$MKDIR_FAIL_LOCK" SI_TEST_MKDIR_COUNT="$MKDIR_COUNT" \
    SI_TEST_BIND_EXTRA="$BIND_EXTRA" SI_TEST_RESTORE_FAIL="$RESTORE_FAIL" \
    SI_TEST_RESTORE_BAD_ROOT="$RESTORE_BAD_ROOT" \
    SI_TEST_STAT_FLIP="$STAT_FLIP" SI_TEST_STAT_FILE="$STAT_FILE" SI_TEST_STAT_CHANGED="$T/stat.changed" \
    SI_TEST_NS_PLANT_ROOT="$PLANT_ROOT" \
    "$TEST_SH" "$RUN_FIX"
  [ "$_dry" = 1 ] && set -- "$@" -n
  "$@" 2>&1
}
seed_seen() {   # $1=数据目录；写一个本 boot/本 ns 的 com.victim 证据
  mkdir -p "$1" || return 1
  printf 'com.victim|%s|%s|/0/Android/data/com.victim/sdcard\n' "$TEST_BOOT" "$TEST_NS" > "$1/.sandbox_seen"
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

# ---------- 0) K 登记 pkg|boot|ns|SB；dry-run 不写状态；去重/200 行 ----------
D0=$T/data0; rm -rf "$D0"; mkdir -p "$D0"
healthy_mi
out=$(run_fix "$D0" 1); r=$(result "$out")
[ ! -e "$D0/.sandbox_seen" ] && [ ! -e "$D0/.fuse_dev" ] \
  && ok "dry-run 不写 .sandbox_seen/.fuse_dev" \
  || bad "dry-run 写了状态文件"
i=1
while [ "$i" -le 205 ]; do
  echo "com.old$i|oldboot|$TEST_NS|/0/Android/data/com.old$i/sdcard"
  i=$((i + 1))
done > "$D0/.sandbox_seen"
out=$(run_fix "$D0" 0); r=$(result "$out")
grep -qxF "com.victim|$TEST_BOOT|$TEST_NS|/0/Android/data/com.victim/sdcard" "$D0/.sandbox_seen" 2>/dev/null \
  && ok "识别到合法沙箱后登记 pkg/boot/ns/SB" \
  || bad "合法沙箱没有按身份登记：$(head -3 "$D0/.sandbox_seen" 2>/dev/null)"
n=$(wc -l < "$D0/.sandbox_seen" 2>/dev/null)
[ "${n:-0}" -le 200 ] && ok "登记后仍限制在 200 行（$n）" || bad "登记后 $n 行（超过 200）"
[ -s "$D0/.fuse_dev" ] && ok "非 dry 记录 .fuse_dev" || bad "非 dry 没有记录 .fuse_dev"
out=$(run_fix "$D0" 0); r=$(result "$out")
n=$(wc -l < "$D0/.sandbox_seen" 2>/dev/null)
c=$(grep -cxF "com.victim|$TEST_BOOT|$TEST_NS|/0/Android/data/com.victim/sdcard" "$D0/.sandbox_seen" 2>/dev/null)
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
grep -qxF 'gone com.victim' "$D2/.sandbox_report" 2>/dev/null \
  && ok "报告文件记录 gone com.victim" || bad "报告文件缺少 gone：$(cat "$D2/.sandbox_report" 2>/dev/null)"
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
rm -rf "$SRC/0/Android/data/com.victim"
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
mkdir -p "$P/124/ns" || exit 1
ln -sf "$TEST_NS" "$P/124/ns/mnt"
mkproc 124 1100
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
has "$r" 'broken=0' && ok "僵死不计 broken（模块不能原地修）" || bad "僵死被计入 broken：$r"
has "$out" '需要重启应用' && ok "日志提示需要重启应用" || bad "日志没有提示重启：$out"
grep -qxF 'stale com.victim' "$D9/.sandbox_report" 2>/dev/null \
  && ok "报告文件记录 stale com.victim" || bad "报告文件缺少 stale：$(cat "$D9/.sandbox_report" 2>/dev/null)"
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

# ---------- 12) 宿主基准用 /proc/1：模块 self 滞后也能判僵死 ----------
D12=$T/data12; seed_seen "$D12" || exit 1
self_mi 0:286; host_mi 0:382; stale_app_mi
out=$(run_fix "$D12" 0); r=$(result "$out")
has "$r" 'sandbox_stale' && ok "self 滞后时按 /proc/1 基准仍判 sandbox_stale" || bad "宿主基准没生效：$r"
[ ! -s "$T/mount.log" ] && ok "宿主基准僵死不 bind" || bad "僵死仍 bind"
rm -f "$P/1/mountinfo"; self_mi 0:50

# ---------- 13) SB 为空但应用 /storage 是旧 FUSE：报 stale，不发 G ----------
D13=$T/data13; mkdir -p "$D13"
self_mi 0:382; host_mi 0:382
cat > "$MI" <<'M'
101 100 0:382 / /mnt/user/0/emulated rw - fuse /dev/fuse rw
102 100 0:286 / /storage/emulated rw - fuse /dev/fuse rw
M
out=$(run_fix "$D13" 0); r=$(result "$out")
has "$r" 'sandbox_stale' && ok "SB 为空 + /storage 旧 FUSE → sandbox_stale" || bad "分叉态没有报 stale：$r"
has "$r" 'sandbox_gone' && bad "分叉态误报 sandbox_gone：$r" || ok "分叉态不误报 sandbox_gone"
[ ! -s "$T/mount.log" ] && ok "分叉态不 bind" || bad "分叉态仍 bind"
rm -f "$P/1/mountinfo"; self_mi 0:50

# ---------- 14) 重建子目录层保护：DCIM 在别的层时不动 ----------
D14=$T/data14; seed_seen "$D14" || exit 1
base_mi; setup_src || exit 1
printf '201 200 0:99 /0/DCIM /storage/emulated/0/DCIM rw - ext4 /dev/x rw\n' >> "$MI"
out=$(run_fix "$D14" 0); r=$(result "$out")
has "$r" 'sandbox=1' && ok "层保护用例仍重建沙箱" || bad "沙箱没有重建：$r"
has "$r" 'skipped=layer' && ok "DCIM 在别的层 → skipped=layer" || bad "没有报 layer：$r"
grep -q '--bind .*/DCIM ' "$T/mount.log" 2>/dev/null \
  && bad "G 路径仍 bind 了别层的 DCIM" || ok "G 路径没有碰别层的 DCIM"
grep -q ' /storage/emulated/0/DCIM ' "$MI" 2>/dev/null \
  && ok "别层的 DCIM 挂载仍在" || bad "别层的 DCIM 被动了"
grep -q '/storage/emulated/0/DCIM' "$T/umount.log" 2>/dev/null \
  && bad "G 路径 umount 了别层的 DCIM" || ok "G 路径没有 umount 别层 DCIM"

# ---------- 15) 目标 /storage/emulated/0 是普通 FUSE 根：先卸再 bind ----------
D15=$T/data15; seed_seen "$D15" || exit 1
base_mi
printf '103 100 0:50 / /storage/emulated/0 rw - fuse /dev/fuse rw\n' >> "$MI"
setup_src || exit 1
out=$(run_fix "$D15" 0); r=$(result "$out")
has "$r" 'sandbox=1' && ok "目标普通 FUSE 根时仍重建" || bad "没有重建：$r"
grep -q '/storage/emulated/0' "$T/umount.log" 2>/dev/null \
  && ok "先卸下普通 FUSE 根再 bind" || bad "没有卸普通 FUSE 根"
grep -q '/Android/data/com.victim/sdcard /storage/emulated/0 ' "$MI" 2>/dev/null \
  && ok "最终 target 是沙箱" || bad "最终 target 不是沙箱：$(cat "$MI")"

# ---------- 16) shared- 别名：源用 shared-<pkg>/sdcard ----------
D16=$T/data16; mkdir -p "$D16"
base_mi
rm -rf "$SRC/0/Android/data/com.victim" "$SRC/0/Android/data/shared-com.shared"
mkdir -p "$SRC/0/Android/data/shared-com.shared/sdcard/DCIM" \
         "$SRC/0/Android/data/shared-com.shared/sdcard/Android/data" \
         "$SRC/0/Android/data/shared-com.shared/sdcard/Android/media" \
         "$SRC/0/Android/data/shared-com.shared/sdcard/Android/obb" \
         "$SRC/0/Android/data/shared-com.shared" \
         "$SRC/0/DCIM" || exit 1
PS_PKG=com.shared
out=$(run_fix "$D16" 0); r=$(result "$out")
PS_PKG=""
has "$r" 'sandbox=1' && ok "shared- 别名能重建" || bad "shared 重建失败：$r"
grep -q '/Android/data/shared-com.shared/sdcard /storage/emulated/0 ' "$MI" 2>/dev/null \
  && ok "shared 源选中 shared-<pkg>/sdcard" || bad "shared 源不对：$(cat "$MI")"

# ---------- 17) cache/sdcard 变体 ----------
D17=$T/data17; mkdir -p "$D17"
base_mi
rm -rf "$SRC/0/Android/data/com.victim"
mkdir -p "$SRC/0/Android/data/com.victim/cache/sdcard/DCIM" \
         "$SRC/0/Android/data/com.victim/cache/sdcard/Android/data" \
         "$SRC/0/Android/data/com.victim/cache/sdcard/Android/media" \
         "$SRC/0/Android/data/com.victim/cache/sdcard/Android/obb" \
         "$SRC/0/Android/data/com.victim" "$SRC/0/DCIM" || exit 1
out=$(run_fix "$D17" 0); r=$(result "$out")
has "$r" 'sandbox=1' && ok "cache/sdcard 变体能重建" || bad "cache 重建失败：$r"
grep -q '/Android/data/com.victim/cache/sdcard /storage/emulated/0 ' "$MI" 2>/dev/null \
  && ok "cache 源选中 /cache/sdcard" || bad "cache 源不对：$(cat "$MI")"

# ---------- 18) 应用 ns 看不到沙箱源：直接 gone，不 bind 也不 umount ----------
D18=$T/data18; seed_seen "$D18" || exit 1
base_mi; setup_src || exit 1
NS_HIDE_PREFIX="$SRC/0"
out=$(run_fix "$D18" 0); r=$(result "$out")
NS_HIDE_PREFIX=""
has "$r" 'sandbox_gone' && ok "应用 ns 看不到源 → sandbox_gone" || bad "没有报 gone：$r"
has "$r" 'fixed=0' && ok "源不可见时 fixed=0" || bad "源不可见仍计 fixed：$r"
[ ! -s "$T/mount.log" ] && ok "源不可见时没有 bind" || bad "源不可见仍 bind：$(cat "$T/mount.log")"
[ ! -s "$T/umount.log" ] && ok "源不可见时没有 umount（没动过挂载）" \
  || bad "源不可见仍 umount：$(cat "$T/umount.log")"
grep -qxF 'gone com.victim' "$D18/.sandbox_report" 2>/dev/null \
  && ok "报告文件记录 gone com.victim" || bad "报告文件缺少 gone"

# ---------- 20) dev 对、source 错：真脚本回滚；去掉校验的改坏版应失败 ----------
D20=$T/data20; seed_seen "$D20" || exit 1
base_mi; setup_src || exit 1
BIND_WRONG_SRC=1
out=$(run_fix "$D20" 0); r=$(result "$out")
BIND_WRONG_SRC=0
has "$r" 'sandbox_gone' && ok "source 错（dev 对）→ sandbox_gone" || bad "source 错没有拦住：$r"
has "$r" 'fixed=0' && ok "source 错不计 fixed" || bad "source 错仍计 fixed：$r"
grep -q ' /storage/emulated/0 ' "$MI" 2>/dev/null && bad "source 错后沙箱行还在" || ok "source 错已回滚"

cp scripts/si-config.awk "$T/si-config.awk" || exit 1
sed 's/sandbox_src_match "$rb_s" "$rb_id" || rb_ok=1/:/' "$FIX" > "$T/fix-broken.sh" || exit 1
D21=$T/data21; seed_seen "$D21" || exit 1
base_mi; setup_src || exit 1
BIND_WRONG_SRC=1; RUN_FIX=$T/fix-broken.sh
out=$(run_fix "$D21" 0); r=$(result "$out")
BIND_WRONG_SRC=0; RUN_FIX=$FIX
has "$r" 'sandbox_gone' && bad "删掉 source 校验的改坏版仍被当成失败（测试没抓住）" \
  || ok "删掉 source 校验的改坏版会假成功（本用例能抓住）"

# ---------- 22) 换 boot：旧 boot 证据不作为资格 ----------
D22=$T/data22; mkdir -p "$D22"
printf 'com.victim|oldboot|%s|/0/Android/data/com.victim/sdcard\n' "$TEST_NS" > "$D22/.sandbox_seen"
base_mi; setup_src || exit 1
out=$(run_fix "$D22" 0); r=$(result "$out")
has "$r" 'sandbox_gone' && bad "旧 boot 证据仍触发重建：$r" || ok "换 boot 后旧 seen 不作为资格（静默）"
has "$r" 'broken=0' && ok "旧 boot 静默不增加 broken" || bad "旧 boot 被计入 broken：$r"
[ ! -s "$T/mount.log" ] && ok "旧 boot 不 bind" || bad "旧 boot 仍 bind"

# ---------- 23) 升级缺口：seen 为空时凭源目录+属主重建 ----------
D23=$T/data23; mkdir -p "$D23"
base_mi; setup_src || exit 1
out=$(run_fix "$D23" 0); r=$(result "$out")
has "$r" 'sandbox=1' && ok "升级后首次扫描（无 seen）凭源目录重建" || bad "升级缺口没有补上：$r"
has "$r" 'broken=1' && ok "升级重建计入 broken" || bad "升级重建 broken 不对：$r"

# ---------- 24) 同一轮先 K 后 G：seen 初始为空也要重建坏包 ----------
D24=$T/data24; mkdir -p "$D24"
mkdir -p "$P/122/ns" || exit 1
ln -sf "$TEST_NS" "$P/122/ns/mnt"
base_mi; setup_src || exit 1
cat > "$P/122/mountinfo" <<'M'
101 100 0:50 / /storage/emulated rw - fuse /dev/fuse rw
200 1 0:50 /0/Android/data/com.good/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
M
PS_TWO=1
out=$(run_fix "$D24" 0); r=$(result "$out")
PS_TWO=0
has "$r" 'sandbox=1' && ok "同轮 K 先于 G：坏包仍被重建（sandbox=1）" || bad "同轮 K 后 G 被静默：$r"
f=$(num "$r" fixed)
[ "${f:-0}" -gt 0 ] && ok "同轮 K 后 G 的 fixed>0（实际 $f）" || bad "同轮 K 后 G 没有修复：$r"
has "$out" '重建沙箱: com.victim' && ok "日志出现坏包重建行" || bad "缺少坏包重建日志：$out"
grep -qxF "com.good|$TEST_BOOT|$TEST_NS|/0/Android/data/com.good/sdcard" "$D24/.sandbox_seen" 2>/dev/null \
  && ok "健康包 K 已登记本 boot/ns 证据" || bad "健康包没有登记：$(cat "$D24/.sandbox_seen" 2>/dev/null)"

# ---------- 25) init /storage 旧、/mnt 新：按 /mnt 判 stale ----------
D25=$T/data25; seed_seen "$D25" || exit 1
self_mi 0:318
cat > "$P/1/mountinfo" <<'M'
100 1 0:50 / / rw - ext4 /dev/root rw
101 100 0:382 / /mnt/user/0/emulated rw - fuse /dev/fuse rw
102 100 0:318 / /storage/emulated rw - fuse /dev/fuse rw
M
cat > "$MI" <<'M'
101 100 0:318 / /mnt/user/0/emulated rw - fuse /dev/fuse rw
102 100 0:318 / /storage/emulated rw - fuse /dev/fuse rw
200 1 0:318 /0/Android/data/com.victim/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
M
out=$(run_fix "$D25" 0); r=$(result "$out")
has "$r" 'sandbox_stale' && ok "init /storage 旧、/mnt 新 → 判 stale" || bad "/storage 基准把旧 FUSE 判健康：$r"
[ ! -s "$T/mount.log" ] && ok "基准分叉时不 bind" || bad "基准分叉仍 bind"
rm -f "$P/1/mountinfo"; self_mi 0:50

# ---------- 26) 旧格式 seen 被忽略：仍可凭源+属主重建 ----------
D26=$T/data26; mkdir -p "$D26"
printf 'com.victim\n' > "$D26/.sandbox_seen"
base_mi; setup_src || exit 1
out=$(run_fix "$D26" 0); r=$(result "$out")
has "$r" 'sandbox=1' && ok "旧格式 seen 行被忽略，升级兜底仍重建" || bad "旧格式 seen 挡住了兜底：$r"
{ [ ! -e "$D26/.sandbox_seen" ] || ! grep -qxF 'com.victim' "$D26/.sandbox_seen"; } 2>/dev/null \
  && ok "旧格式行已被丢弃（不再作为证据）" || bad "旧格式行还在：$(cat "$D26/.sandbox_seen" 2>/dev/null)"

# ---------- 27) 无 SB + 两个变体都在 → ambiguous，不 bind ----------
D27=$T/data27; mkdir -p "$D27"
base_mi; setup_src || exit 1
mkdir -p "$SRC/0/Android/data/shared-com.victim/sdcard" || exit 1
out=$(run_fix "$D27" 0); r=$(result "$out")
rm -rf "$SRC/0/Android/data/shared-com.victim"
has "$r" 'sandbox_gone' && ok "多源变体无 SB → sandbox_gone" || bad "变体歧义没有 fail-closed：$r"
has "$out" '拒绝猜测' && ok "日志说明拒绝猜测" || bad "日志没有歧义说明：$out"
[ ! -s "$T/mount.log" ] && ok "变体歧义时不 bind" || bad "变体歧义仍 bind：$(cat "$T/mount.log")"

# ---------- 28) 沙箱 umount 失败：不把原 FUSE 根叠回去，保留现状 ----------
# 场景：普通根先被卸下 → 沙箱 bind 校验失败 → 只让沙箱层 umount 失败。
# 失败后 target 必须仍只有沙箱一层（不能再把 root 叠上去，否则隔离被击穿）。
D28=$T/data28; seed_seen "$D28" || exit 1
base_mi
printf '103 100 0:50 / /storage/emulated/0 rw - fuse /dev/fuse rw\n' >> "$MI"
setup_src || exit 1
BIND_BAD=1; UMOUNT_FAIL=2
out=$(run_fix "$D28" 0); r=$(result "$out")
BIND_BAD=0; UMOUNT_FAIL=0
has "$r" 'rollback' && ok "umount 失败打 rollback tag" || bad "umount 失败没有 rollback tag：$r"
has "$r" 'sandbox_stale' && ok "umount 失败按 sandbox_stale 上报" || bad "umount 失败没有报 stale：$r"
has "$r" 'sandbox_gone' && bad "umount 失败仍混入 sandbox_gone：$r" || ok "umount 失败不混入 sandbox_gone"
has "$r" 'retry=' && bad "umount 失败仍安排重试：$r" || ok "umount 失败不安排重试"
has "$out" '保留现状' && ok "日志明确说明保留现状" || bad "日志没有保留现状：$out"
n=$(awk '$5 == "/storage/emulated/0" { n++ } END { print n + 0 }' "$MI" 2>/dev/null)
[ "$n" = 1 ] && ok "失败后 target 恰 1 层（$n）" || bad "失败后 target 层数不对：$n"
top=$(awk '$5 == "/storage/emulated/0" { r = $4 } END { print r }' "$MI" 2>/dev/null)
case "$top" in
  */Android/data/com.victim/*) ok "失败后栈顶仍是沙箱（没有把原根叠上去）" ;;
  *) bad "失败后栈顶不是沙箱：$top" ;;
esac
grep -q ' / /storage/emulated/0 ' "$MI" 2>/dev/null \
  && bad "umount 失败后仍恢复了原 FUSE 根（隔离被击穿）" \
  || ok "umount 失败后没有恢复原 FUSE 根"
grep -qxF 'stale com.victim' "$D28/.sandbox_report" 2>/dev/null \
  && ok "回滚未卸干净按 stale 上报（需重启应用）" \
  || bad "回滚未卸干净没有按 stale 上报：$(cat "$D28/.sandbox_report" 2>/dev/null)"

# ---------- 29) 普通 FUSE 根先卸后 bind 失败：挂回原根 ----------
D29=$T/data29; seed_seen "$D29" || exit 1
base_mi
printf '103 100 0:50 / /storage/emulated/0 rw - fuse /dev/fuse rw\n' >> "$MI"
setup_src || exit 1
BIND_WRONG_SRC=1
out=$(run_fix "$D29" 0); r=$(result "$out")
BIND_WRONG_SRC=0
has "$r" 'sandbox_gone' && ok "原根恢复用例仍报 gone" || bad "没有报 gone：$r"
has "$out" '已把原 FUSE 根挂回' && ok "失败后把原 FUSE 根挂回" || bad "原 FUSE 根没有恢复：$out"
grep -q ' / /storage/emulated/0 ' "$MI" 2>/dev/null \
  && ok "target 上恢复为普通 FUSE 根" || bad "target 没有恢复：$(cat "$MI" 2>/dev/null)"

# ---------- 30) 普通 FUSE 根 root=/0 也能先卸再挂 ----------
D30=$T/data30; seed_seen "$D30" || exit 1
base_mi
printf '103 100 0:50 /0 /storage/emulated/0 rw - fuse /dev/fuse rw\n' >> "$MI"
setup_src || exit 1
out=$(run_fix "$D30" 0); r=$(result "$out")
has "$r" 'sandbox=1' && ok "target root=/0 时仍重建" || bad "root=/0 被当成别的层：$r"
grep -q '/Android/data/com.victim/sdcard /storage/emulated/0 ' "$MI" 2>/dev/null \
  && ok "root=/0 卸下后挂上沙箱" || bad "root=/0 没有挂上沙箱"

# ---------- 31) 共享源缺失 → 回滚沙箱 ----------
D31=$T/data31; seed_seen "$D31" || exit 1
base_mi; setup_src || exit 1
rm -rf "$SRC/0/DCIM"
out=$(run_fix "$D31" 0); r=$(result "$out")
has "$r" 'sandbox_gone' && ok "共享源缺失 → sandbox_gone" || bad "共享源缺失没有回滚：$r"
has "$r" 'fixed=0' && ok "共享源缺失不计 fixed" || bad "共享源缺失仍计 fixed：$r"
grep -q ' /storage/emulated/0 ' "$MI" 2>/dev/null && bad "共享源缺失留了空沙箱" || ok "共享源缺失已回滚沙箱"

# ---------- 32) 共享 bindfail → 回滚沙箱 ----------
D32=$T/data32; seed_seen "$D32" || exit 1
base_mi; setup_src || exit 1
BIND_FAIL_TGT=/storage/emulated/0/DCIM
out=$(run_fix "$D32" 0); r=$(result "$out")
BIND_FAIL_TGT=""
has "$r" 'sandbox_gone' && ok "共享 bindfail → sandbox_gone" || bad "bindfail 没有回滚：$r"
grep -q ' /storage/emulated/0 ' "$MI" 2>/dev/null && bad "bindfail 留了空沙箱" || ok "bindfail 已回滚沙箱"

# ---------- 33) bind 后应用内不可读 → 回滚 ----------
D33=$T/data33; seed_seen "$D33" || exit 1
base_mi; setup_src || exit 1
NS_TARGET_UNREADABLE=1
out=$(run_fix "$D33" 0); r=$(result "$out")
NS_TARGET_UNREADABLE=0
has "$r" 'sandbox_gone' && ok "target 不可读 → sandbox_gone" || bad "不可读没有回滚：$r"
has "$out" '不可读' && ok "日志说明不可读回滚" || bad "日志没有不可读：$out"
grep -q ' /storage/emulated/0 ' "$MI" 2>/dev/null && bad "不可读后沙箱还在" || ok "不可读后已回滚"

# ---------- 34) sdcard 与 cache/sdcard 同时存在 → ambiguous ----------
D34=$T/data34; mkdir -p "$D34"
base_mi; setup_src || exit 1
mkdir -p "$SRC/0/Android/data/com.victim/cache/sdcard" || exit 1
out=$(run_fix "$D34" 0); r=$(result "$out")
has "$r" 'sandbox_gone' && ok "sdcard/cache 双变体无 SB → sandbox_gone" || bad "cache 歧义没有 fail-closed：$r"
has "$out" '拒绝猜测' && ok "cache 歧义日志说明拒绝猜测" || bad "cache 歧义日志不对：$out"
[ ! -s "$T/mount.log" ] && ok "cache 歧义不 bind" || bad "cache 歧义仍 bind"

# ---------- 35) R3 主扫描栈顶/层数：target 叠了两层 → rollback，不登记 K ----------
D35=$T/data35; seed_seen "$D35" || exit 1
cat > "$MI" <<'M'
101 100 0:50 / /mnt/user/0/emulated rw - fuse /dev/fuse rw
102 100 0:50 / /storage/emulated rw - fuse /dev/fuse rw
200 1 0:50 /0/Android/data/com.victim/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
103 100 0:50 / /storage/emulated/0 rw - fuse /dev/fuse rw
M
out=$(run_fix "$D35" 0); r=$(result "$out")
has "$r" 'rollback' && ok "target 叠层 → skipped=rollback" || bad "叠层没有报 rollback：$r"
has "$r" 'sandbox_stale' && bad "叠层被误报为可重建 stale：$r" || ok "叠层不误报 sandbox_stale"
has "$r" 'broken=0' && ok "叠层不计 broken（跨 ns 不能原地修）" || bad "叠层被计入 broken：$r"
has "$out" '需要重启应用' && ok "叠层提示重启应用" || bad "叠层没有提示重启：$out"
[ "$(wc -l < "$D35/.sandbox_seen" 2>/dev/null)" = 1 ] \
  && ok "叠层没有登记新的 K 证据" || bad "叠层登记了 K：$(cat "$D35/.sandbox_seen" 2>/dev/null)"
[ ! -s "$T/mount.log" ] && [ ! -s "$T/umount.log" ] && ok "叠层不动挂载" || bad "叠层仍动挂载"
grep -qxF 'stale com.victim' "$D35/.sandbox_report" 2>/dev/null \
  && ok "叠层按 stale 上报" || bad "叠层没有 stale 上报"

# ---------- 36) R3 残留非本包沙箱：阻止 K、报 stale、不动挂载 ----------
D36=$T/data36; seed_seen "$D36" || exit 1
cat > "$MI" <<'M'
101 100 0:50 / /mnt/user/0/emulated rw - fuse /dev/fuse rw
102 100 0:50 / /storage/emulated rw - fuse /dev/fuse rw
200 1 0:50 /0/Android/data/com.other/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
M
out=$(run_fix "$D36" 0); r=$(result "$out")
has "$r" 'identity' && ok "残留他包沙箱报 identity" || bad "残留他包沙箱没有拦住：$r"
has "$r" 'sandbox_gone' && bad "残留他包沙箱被当成可重建：$r" || ok "残留他包沙箱不报 sandbox_gone"
[ "$(wc -l < "$D36/.sandbox_seen" 2>/dev/null)" = 1 ] \
  && ok "残留他包沙箱阻止 K 登记" || bad "残留他包沙箱仍登记 K"
grep -qxF 'stale com.victim' "$D36/.sandbox_report" 2>/dev/null \
  && ok "残留他包沙箱按 stale 上报（需重启应用）" || bad "残留他包沙箱没有 stale 上报"
[ ! -s "$T/mount.log" ] && [ ! -s "$T/umount.log" ] && ok "残留他包沙箱不动挂载" || bad "残留他包沙箱仍动挂载"

# ---------- 37) R4 无同 ns 证据 + 普通 FUSE 根：不卸不 bind，报 sandbox_skip ----------
D37=$T/data37; mkdir -p "$D37"
base_mi
printf '103 100 0:50 / /storage/emulated/0 rw - fuse /dev/fuse rw\n' >> "$MI"
setup_src || exit 1
out=$(run_fix "$D37" 0); r=$(result "$out")
has "$r" 'sandbox_skip' && ok "无证据的普通根报 sandbox_skip" || bad "没有报 sandbox_skip：$r"
has "$r" 'sandbox_gone' && bad "策略拒绝被误报为可重试的 sandbox_gone：$r" || ok "策略拒绝不复用 sandbox_gone"
has "$r" 'fixed=0' && ok "策略拒绝不计 fixed" || bad "策略拒绝仍计 fixed：$r"
has "$r" 'broken=1' && ok "策略拒绝仍计需修复" || bad "策略拒绝没计 broken：$r"
[ ! -s "$T/mount.log" ] && ok "普通根不 bind" || bad "普通根仍 bind：$(cat "$T/mount.log")"
[ ! -s "$T/umount.log" ] && ok "普通根不 umount" || bad "普通根仍 umount：$(cat "$T/umount.log")"
grep -q ' / /storage/emulated/0 ' "$MI" 2>/dev/null \
  && ok "普通 FUSE 根保持原样" || bad "普通 FUSE 根被动了"
grep -qxF 'skip com.victim' "$D37/.sandbox_report" 2>/dev/null \
  && ok "报告文件记录 skip com.victim" || bad "报告文件缺少 skip"

# ---------- 38) E-P1 同 boot 异 ns：n=0 回落重建；普通根不拆 ----------
D38=$T/data38; mkdir -p "$D38"
printf 'com.victim|%s|mnt:[4026539999]|/0/Android/data/com.victim/sdcard\n' "$TEST_BOOT" > "$D38/.sandbox_seen"
base_mi; setup_src || exit 1
out=$(run_fix "$D38" 0); r=$(result "$out")
has "$r" 'sandbox=1' && ok "同 boot 异 ns（n=0）回落源+属主重建" || bad "异 ns 回落失败：$r"
has "$r" 'sandbox_skip' && bad "n=0 被策略拒绝：$r" || ok "n=0 不走普通根策略"

D38b=$T/data38b; mkdir -p "$D38b"
# 混合行：本 boot 旧 ns + 别的 boot；本 boot 有行就不能否决回落，但普通根仍按 R4 拒绝。
printf 'com.victim|%s|mnt:[4026539999]|/0/Android/data/com.victim/sdcard\ncom.victim|oldboot|mnt:[4026539998]|/0/Android/data/com.victim/sdcard\n' \
  "$TEST_BOOT" > "$D38b/.sandbox_seen"
base_mi
printf '103 100 0:50 / /storage/emulated/0 rw - fuse /dev/fuse rw\n' >> "$MI"
setup_src || exit 1
out=$(run_fix "$D38b" 0); r=$(result "$out")
has "$r" 'sandbox_skip' && ok "同 boot 异 ns + 普通根 → sandbox_skip" || bad "异 ns 拆了普通根：$r"
[ ! -s "$T/mount.log" ] && ok "异 ns 普通根不 bind" || bad "异 ns 普通根仍 bind"

# ---------- 39) K 的空 ns 不落盘 ----------
D39=$T/data39; mkdir -p "$D39"
healthy_mi
rm -f "$P/123/ns/mnt"
out=$(run_fix "$D39" 0); r=$(result "$out")
has "$r" 'checked=1' && ok "空 ns 用例仍完成扫描" || bad "空 ns 用例没扫描：$r"
[ ! -s "$D39/.sandbox_seen" ] && ok "ns 读不到时不写空 ns 行" \
  || bad "写入了空 ns 行：$(cat "$D39/.sandbox_seen" 2>/dev/null)"
ln -sf "$TEST_NS" "$P/123/ns/mnt"

# ---------- 40) R2 沙箱失败退避：同 dev/boot/ns 不重试，时间到/换 dev 才重试 ----------
D40=$T/data40; seed_seen "$D40" || exit 1
base_mi; setup_src || exit 1
NS_HIDE_PREFIX="$SRC/0"; TEST_NOW=1000; TEST_MONO=5000
out=$(run_fix "$D40" 0); r=$(result "$out"); n1=$(wc -l < "$T/nsenter.log" 2>/dev/null)
has "$r" 'sandbox_gone' && ok "R2 首轮失败报 gone" || bad "R2 首轮没有失败：$r"
[ "${n1:-0}" -gt 0 ] && ok "R2 首轮实际探测过（nsenter $n1 次）" || bad "R2 首轮没探测"
TEST_NOW=1100; TEST_MONO=5100
out=$(run_fix "$D40" 0); r=$(result "$out")
has "$r" 'sandbox_gone' && ok "R2 退避期仍上报 gone（状态不丢）" || bad "R2 退避期状态丢了：$r"
has "$r" 'retry=' && ok "R2 退避期 RESULT 带 retry=" || bad "R2 退避期没有 retry：$r"
[ ! -s "$T/nsenter.log" ] && [ ! -s "$T/mount.log" ] \
  && ok "R2 退避期不再 nsenter/mount" || bad "R2 退避期仍探测：$(cat "$T/nsenter.log" "$T/mount.log" 2>/dev/null)"
TEST_NOW=1250; TEST_MONO=5250
out=$(run_fix "$D40" 0); r=$(result "$out")
[ -s "$T/nsenter.log" ] && ok "R2 时间到期后重新探测" || bad "R2 时间到期仍不重试"
ln -sf 'mnt:[4026532002]' "$P/123/ns/mnt"
TEST_NOW=1260; TEST_MONO=5260
out=$(run_fix "$D40" 0); r=$(result "$out")
[ -s "$T/nsenter.log" ] && ok "R2 换 namespace 后立即失效退避" || bad "R2 换 ns 后仍退避"
ln -sf "$TEST_NS" "$P/123/ns/mnt"
TEST_NOW=""; TEST_MONO=""; NS_HIDE_PREFIX=""

# ---------- 41) R2 repair_one 退避：source/bindfail 不每轮重试 ----------
D41=$T/data41; seed_seen "$D41" || exit 1
sandbox_ok_mi; setup_src || exit 1
mkdir -p "$DATA/media/0/Android/data/com.victim/sdcard/DCIM" || exit 1
BIND_FAIL_TGT=/storage/emulated/0/DCIM; TEST_NOW=2000; TEST_MONO=6000
out=$(run_fix "$D41" 0); r=$(result "$out")
has "$out" '失败 DCIM' && ok "R2 repair 首轮 bind 失败" || bad "R2 repair 首轮没有失败：$out"
[ -s "$T/mount.log" ] && ok "R2 repair 首轮实际 bind" || bad "R2 repair 首轮没 bind"
TEST_NOW=2100; TEST_MONO=6100
out=$(run_fix "$D41" 0); r=$(result "$out")
has "$r" 'retry=' && ok "R2 repair 退避期带 retry=" || bad "R2 repair 退避期没有 retry：$r"
[ ! -s "$T/mount.log" ] && ok "R2 repair 退避期不再 bind" || bad "R2 repair 退避期仍 bind：$(cat "$T/mount.log")"
TEST_NOW=2200; TEST_MONO=6200
out=$(run_fix "$D41" 0); r=$(result "$out")
[ -s "$T/mount.log" ] && ok "R2 repair 时间到期后重新 bind" || bad "R2 repair 到期仍不重试"
BIND_FAIL_TGT=""; TEST_NOW=""; TEST_MONO=""

# ---------- 42) 锁目录建不出来 → error=datadir，而不是静默 exit 0 ----------
D42=$T/data42; rm -rf "$D42"; mkdir -p "$D42/.si-fix.lock"
printf '555\n' > "$D42/.si-fix.lock/pid"
mkdir -p "$P/555" || exit 1
printf 'com.example\n' > "$P/555/cmdline"
MKDIR_FAIL_LOCK=$D42/.si-fix.lock; MKDIR_COUNT=$T/mkdir.count; rm -f "$MKDIR_COUNT"
out=$(run_fix "$D42" 0); r=$(result "$out")
MKDIR_FAIL_LOCK=""; MKDIR_COUNT=""
has "$r" 'error=datadir' && ok "锁目录建不出来报 error=datadir" \
  || bad "锁目录失败没有 RESULT：[$r] / $out"
has "$r" 'skipped=locked' && bad "锁目录失败被误报成另一轮在跑：$r" \
  || ok "锁目录失败不误报 locked"

# ---------- 43) 普通根 umount 未生效：不谎报已卸下 ----------
D43=$T/data43; seed_seen "$D43" || exit 1
base_mi
printf '103 100 0:50 / /storage/emulated/0 rw - fuse /dev/fuse rw\n' >> "$MI"
setup_src || exit 1
UMOUNT_FAIL=3
out=$(run_fix "$D43" 0); r=$(result "$out")
UMOUNT_FAIL=0
has "$out" 'umount 未生效' && ok "普通根 umount 未生效有明确日志" || bad "日志没说明 umount 未生效：$out"
has "$out" '已卸下后重挂沙箱' && bad "umount 失败却宣称已卸下：$out" || ok "umount 失败不谎报已卸下"
has "$r" 'rollback' && bad "普通根仍在却被标 rollback：$r" || ok "普通根仍在时不标 rollback"
has "$r" 'sandbox_gone' && ok "umount 未生效按 gone 上报" || bad "umount 未生效没有报 gone：$r"
[ ! -s "$T/mount.log" ] && ok "umount 未生效时不 bind" || bad "umount 未生效仍 bind"
grep -q ' / /storage/emulated/0 ' "$MI" 2>/dev/null && ok "普通根保持原样" || bad "普通根被动了"

# ---------- 44) bind 后 n>1：与主扫描一致，不计 fixed ----------
D44=$T/data44; seed_seen "$D44" || exit 1
base_mi; setup_src || exit 1
BIND_EXTRA=1
out=$(run_fix "$D44" 0); r=$(result "$out")
BIND_EXTRA=0
has "$r" 'rollback' && ok "并发挂载报 rollback" || bad "并发挂载没有报 rollback：$r"
has "$r" 'sandbox_stale' && ok "并发挂载报 sandbox_stale" || bad "并发挂载没有报 stale：$r"
has "$r" 'sandbox_gone' && bad "并发挂载仍混入 sandbox_gone：$r" || ok "并发挂载不混入 sandbox_gone"
has "$r" 'retry=' && bad "并发挂载仍安排重试：$r" || ok "并发挂载不安排重试"
has "$r" 'fixed=0' && ok "并发挂载不计 fixed" || bad "并发挂载仍计 fixed：$r"
has "$r" 'sandbox=' && bad "并发挂载仍报 sandbox=：$r" || ok "并发挂载不报 sandbox="
has "$out" '并发挂载' && ok "日志说明并发挂载" || bad "日志没有并发挂载原因：$out"
grep -qxF 'stale com.victim' "$D44/.sandbox_report" 2>/dev/null \
  && ok "并发挂载按 stale 上报" || bad "并发挂载没有 stale 上报"
n=$(awk '$5 == "/storage/emulated/0" { n++ } END { print n + 0 }' "$MI" 2>/dev/null)
[ "$n" = 2 ] && ok "并发挂载保留现状（$n 层）" || bad "并发挂载后层数不对：$n"

# ---------- 45) 沙箱卸了但原根恢复失败：stale，不谎报已回滚 ----------
D45=$T/data45; seed_seen "$D45" || exit 1
base_mi
printf '103 100 0:50 / /storage/emulated/0 rw - fuse /dev/fuse rw\n' >> "$MI"
setup_src || exit 1
BIND_BAD=1; RESTORE_FAIL=1
out=$(run_fix "$D45" 0); r=$(result "$out")
BIND_BAD=0; RESTORE_FAIL=0
has "$out" '原 FUSE 根恢复失败' && ok "恢复失败有明确日志" || bad "没有输出恢复失败：$out"
has "$out" '已回滚' && bad "恢复失败仍宣称已回滚：$out" || ok "恢复失败不谎报已回滚"
has "$r" 'rollback' && ok "恢复失败打 rollback tag" || bad "恢复失败没有 rollback tag：$r"
has "$r" 'sandbox_stale' && ok "恢复失败按 sandbox_stale 上报" || bad "恢复失败没有报 stale：$r"
has "$r" 'sandbox_gone' && bad "恢复失败仍混入 sandbox_gone：$r" || ok "恢复失败不混入 sandbox_gone"
has "$r" 'retry=' && bad "恢复失败仍安排重试：$r" || ok "恢复失败不安排重试"
grep -qxF 'stale com.victim' "$D45/.sandbox_report" 2>/dev/null \
  && ok "恢复失败按 stale 上报（不是 gone）" || bad "恢复失败没有按 stale 上报：$(cat "$D45/.sandbox_report" 2>/dev/null)"
n=$(awk '$5 == "/storage/emulated/0" { n++ } END { print n + 0 }' "$MI" 2>/dev/null)
[ "$n" = 0 ] && ok "恢复失败后 target 没有挂载（保留现状）" || bad "恢复失败后 target 意外有 $n 层"

# ---------- 46) 空 ns 的 seen 行被过滤，不再当证据 ----------
D46=$T/data46; mkdir -p "$D46"
printf 'com.victim|%s||/0/Android/data/com.victim/sdcard\n' "$TEST_BOOT" > "$D46/.sandbox_seen"
base_mi; setup_src || exit 1
out=$(run_fix "$D46" 0); r=$(result "$out")
has "$r" 'sandbox=1' && ok "空 ns 行被忽略，仍可凭源+属主重建" || bad "空 ns 行挡住了兜底：$r"
grep -q '||' "$D46/.sandbox_seen" 2>/dev/null \
  && bad "空 ns 行仍留在 .sandbox_seen" || ok "空 ns 行已被过滤"

# ---------- 47) 窗口里 SI 把普通根挂回来：拆根前第二道守卫仍拒绝 ----------
D47=$T/data47; mkdir -p "$D47"
base_mi; setup_src || exit 1
PLANT_ROOT=1
out=$(run_fix "$D47" 0); r=$(result "$out")
PLANT_ROOT=0
has "$r" 'sandbox_skip' && ok "窗口里出现的普通根被第二道守卫拒绝" || bad "第二道守卫没拦住：$r"
[ ! -s "$T/mount.log" ] && [ ! -s "$T/umount.log" ] \
  && ok "第二道守卫不动挂载" || bad "第二道守卫仍动挂载：$(cat "$T/mount.log" "$T/umount.log" 2>/dev/null)"
grep -qxF 'skip com.victim' "$D47/.sandbox_report" 2>/dev/null \
  && ok "第二道守卫按 skip 上报" || bad "第二道守卫没有 skip 上报"

# ---------- 48) P1 混合 seen：本 boot 有旧 ns 行 + 旧 boot 行，n=0 仍回落 ----------
D48=$T/data48; mkdir -p "$D48"
printf 'com.victim|%s|mnt:[4026539999]|/0/Android/data/com.victim/sdcard\ncom.victim|oldboot|mnt:[4026539998]|/0/Android/data/com.victim/sdcard\n' \
  "$TEST_BOOT" > "$D48/.sandbox_seen"
base_mi; setup_src || exit 1
out=$(run_fix "$D48" 0); r=$(result "$out")
has "$r" 'sandbox=1' && ok "混合 seen（本 boot 旧 ns + 旧 boot）n=0 仍回落重建" \
  || bad "混合 seen 否决了回落：$r"
has "$r" 'broken=1' && ok "混合 seen 回落计入 broken" || bad "混合 seen 没有计入 broken：$r"
has "$r" 'sandbox_skip' && bad "混合 seen n=0 被安全拒绝：$r" || ok "混合 seen n=0 不走普通根策略"

# ---------- 49) P2 目标被别层占用：sandbox_skip，不 gone/不重试 ----------
D49=$T/data49; seed_seen "$D49" || exit 1
base_mi
printf '200 1 0:99 /other /storage/emulated/0 rw - ext4 /dev/x rw\n' >> "$MI"
setup_src || exit 1
out=$(run_fix "$D49" 0); r=$(result "$out")
has "$r" 'sandbox_skip' && ok "目标被别层占用报 sandbox_skip" || bad "目标被占用没有报 skip：$r"
has "$r" 'sandbox_gone' && bad "目标被占用仍报可重试的 sandbox_gone：$r" || ok "目标被占用不复用 sandbox_gone"
has "$r" 'retry=' && bad "目标被占用仍安排重试：$r" || ok "目标被占用不安排重试"
has "$out" '目标被其他挂载占用' && ok "日志说明目标被占用" || bad "日志没说明目标被占用：$out"
has "$out" '需要重启应用' && ok "日志提示需要重启应用" || bad "日志没有提示重启：$out"
[ ! -s "$T/mount.log" ] && [ ! -s "$T/umount.log" ] \
  && ok "目标被占用时不动挂载" || bad "目标被占用仍动挂载"
grep -qxF 'skip com.victim' "$D49/.sandbox_report" 2>/dev/null \
  && ok "目标被占用按 skip 上报" || bad "目标被占用没有 skip 上报"
# 第二轮必须仍然 skip：若改回 gone，这里会进入 180s 退避并出现 gone+retry。
out=$(run_fix "$D49" 0); r=$(result "$out")
has "$r" 'sandbox_skip' && ok "目标被占用第二轮仍报 skip" || bad "第二轮不再报 skip：$r"
has "$r" 'sandbox_gone' && bad "第二轮混入 sandbox_gone：$r" || ok "第二轮不混入 sandbox_gone"
has "$r" 'retry=' && bad "第二轮出现无效重试：$r" || ok "第二轮没有 retry"
[ ! -s "$T/mount.log" ] && [ ! -s "$T/umount.log" ] \
  && ok "第二轮仍不动挂载" || bad "第二轮动了挂载"

# ---------- 50) 子进程 pkg:push 单独 ns：按基础包名查配置 ----------
D50=$T/data50; seed_seen "$D50" || exit 1
base_mi; setup_src || exit 1
mkdir -p "$P/124" "$P/124/ns" || exit 1
ln -sf 'mnt:[4026532002]' "$P/124/ns/mnt"
mkproc 124 1200
cat > "$P/124/mountinfo" <<'M'
101 100 0:50 / /mnt/user/0/emulated rw - fuse /dev/fuse rw
102 100 0:50 / /storage/emulated rw - fuse /dev/fuse rw
M
PS_SUB=1; MI_DIR_OVERRIDE=$P
out=$(run_fix "$D50" 0); r=$(result "$out")
PS_SUB=0; MI_DIR_OVERRIDE=""
has "$r" 'checked=2' && ok "pkg:push 也按已隔离进程扫描（checked=2）" || bad "pkg:push 没进扫描：$r"
has "$r" 'sandbox=2' && ok "主进程与 pkg:push 两个 ns 都重建（sandbox=2）" || bad "子进程没重建：$r"
grep -q '/Android/data/com.victim/sdcard /storage/emulated/0 ' "$P/123/mountinfo" 2>/dev/null \
  && ok "主进程 ns 挂上沙箱" || bad "主进程没挂上"
grep -q '/Android/data/com.victim/sdcard /storage/emulated/0 ' "$P/124/mountinfo" 2>/dev/null \
  && ok "pkg:push 的 ns 挂上沙箱" || bad "子进程没挂上"
rm -rf "$P/124"

# ---------- 51) custom_dirs 含 sandbox：目录失败行不能撞沙箱退避键 ----------
D51=$T/data51; seed_seen "$D51" || exit 1
sandbox_ok_mi; setup_src || exit 1
mkdir -p "$DATA/media/0/Android/data/com.victim/sdcard/sandbox" "$SRC/0/sandbox" || exit 1
cat > "$T/conf51.json" <<'J'
{"apps":[{"package_name":"com.victim","enabled":true,"mount_dirs":{"custom_dirs":["sandbox"]}}]}
J
CONF_FILE=$T/conf51.json; BIND_FAIL_TGT=/storage/emulated/0/sandbox; TEST_NOW=3000; TEST_MONO=7000
out=$(run_fix "$D51" 0); r=$(result "$out")
BIND_FAIL_TGT=""
grep -q ' com.victim sandbox failed' "$D51/.repairs" 2>/dev/null \
  && ok "自定义目录 sandbox 的失败行已写入" || bad "目录失败行没写入：$(cat "$D51/.repairs" 2>/dev/null)"
# 制造沙箱丢失（只留子目录挂载），同 NOW 再跑：不能被目录 sandbox 的失败行挡住
awk '$5 != "/storage/emulated/0"' "$MI" > "$MI.tmp" 2>/dev/null && mv -f "$MI.tmp" "$MI"
NS_HIDE_PREFIX="$SRC/0"
out=$(run_fix "$D51" 0); r=$(result "$out")
has "$r" 'sandbox_gone' && ok "沙箱失败首次仍会尝试（未被目录键退避）" || bad "沙箱被目录失败行挡住：$r"
[ -s "$T/nsenter.log" ] && ok "沙箱失败确实探测过（nsenter）" || bad "沙箱没有探测"
grep -q ' com.victim /@sandbox failed' "$D51/.repairs" 2>/dev/null \
  && ok "沙箱失败行用 /@sandbox 键" || bad "沙箱失败键不对：$(cat "$D51/.repairs" 2>/dev/null)"
out=$(run_fix "$D51" 0); r=$(result "$out")
has "$r" 'retry=' && ok "@sandbox 自己的退避生效" || bad "@sandbox 退避没有生效：$r"
[ ! -s "$T/nsenter.log" ] && ok "@sandbox 退避期不再探测" || bad "退避期仍探测"
CONF_FILE=$T/conf.json; NS_HIDE_PREFIX=""; TEST_NOW=""; TEST_MONO=""; BIND_FAIL_TGT=""

# ---------- 51b) 合法目录 @sandbox 与内部 /@sandbox 键互不干扰 ----------
D51B=$T/data51b; seed_seen "$D51B" || exit 1
sandbox_ok_mi; setup_src || exit 1
mkdir -p "$DATA/media/0/Android/data/com.victim/sdcard/@sandbox" "$SRC/0/@sandbox" || exit 1
cat > "$T/conf51b.json" <<'J'
{"apps":[{"package_name":"com.victim","enabled":true,"mount_dirs":{"custom_dirs":["@sandbox"]}}]}
J
CONF_FILE=$T/conf51b.json; BIND_FAIL_TGT=/storage/emulated/0/@sandbox; TEST_NOW=3100; TEST_MONO=7100
out=$(run_fix "$D51B" 0); r=$(result "$out")
BIND_FAIL_TGT=""
has "$r" 'dir_invalid' && bad "合法目录 @sandbox 被误判无效：$r" \
  || ok "合法目录 @sandbox 不再被黑名单拒绝"
grep -qE ' com\.victim @sandbox($| )' "$D51B/.repairs" 2>/dev/null \
  && ok "目录 @sandbox 的失败行按普通目标记录" \
  || bad "目录 @sandbox 没有失败行：$(cat "$D51B/.repairs" 2>/dev/null)"
grep -qE ' com\.victim /@sandbox($| )' "$D51B/.repairs" 2>/dev/null \
  && bad "目录 @sandbox 写了内部分箱键" || ok "目录 @sandbox 没有写内部 /@sandbox 键"
grep -qE -- '--bind .* /storage/emulated/0/@sandbox$' "$T/mount.log" 2>/dev/null \
  && ok "@sandbox 目录失败前确实尝试过 bind" \
  || bad "没有尝试 bind @sandbox：$(cat "$T/mount.log" 2>/dev/null)"
grep -q ' /storage/emulated/0/@sandbox ' "$MI" 2>/dev/null \
  && bad "失败目录 @sandbox 仍挂进了 mountinfo" || ok "@sandbox 目录失败后未挂进 mountinfo"
# 制造沙箱丢失：同 NOW 再跑，沙箱必须照常探测，不能被目录 @sandbox 的失败行挡住
awk '$5 != "/storage/emulated/0"' "$MI" > "$MI.tmp" 2>/dev/null && mv -f "$MI.tmp" "$MI"
NS_HIDE_PREFIX="$SRC/0"
out=$(run_fix "$D51B" 0); r=$(result "$out")
has "$r" 'sandbox_gone' && ok "沙箱退避未被目录 @sandbox 挡住" || bad "沙箱被目录 @sandbox 挡住：$r"
[ -s "$T/nsenter.log" ] && ok "@sandbox 用例中沙箱仍会探测" || bad "沙箱没有探测"
grep -qE ' com\.victim /@sandbox($| )' "$D51B/.repairs" 2>/dev/null \
  && ok "沙箱失败行使用内部 /@sandbox 键" \
  || bad "沙箱失败键不对：$(cat "$D51B/.repairs" 2>/dev/null)"
CONF_FILE=$T/conf.json; NS_HIDE_PREFIX=""; TEST_NOW=""; TEST_MONO=""

# ---------- 51c) 旧 #SI2 缓存（写着 @sandbox 目录）必须失效，不再 bind @sandbox ----------
D51C=$T/data51c; seed_seen "$D51C" || exit 1
sandbox_ok_mi; setup_src || exit 1
cat > "$T/conf51c.json" <<'J'
{"apps":[{"package_name":"com.victim","enabled":true,"mount_dirs":{"custom_dirs":[]}}]}
J
mkdir -p "$D51C" || exit 1
mkdir -p "$SRC/0/@sandbox" || exit 1
printf '#SI2 %s\n' "$(stat -c '%y:%s' "$T/conf51c.json" 2>/dev/null)" > "$D51C/.conf.cache"
printf '|com.victim=1:@sandbox \n@PKGS com.victim\n' >> "$D51C/.conf.cache"
CONF_FILE=$T/conf51c.json; TEST_NOW=3200; TEST_MONO=7200
out=$(run_fix "$D51C" 0); r=$(result "$out")
CONF_FILE=$T/conf.json; TEST_NOW=""; TEST_MONO=""
grep -qE -- '--bind .* /storage/emulated/0/@sandbox$' "$T/mount.log" 2>/dev/null \
  && bad "旧 #SI2 缓存仍被信任：尝试 bind 了 @sandbox" \
  || ok "旧 #SI2 缓存已失效，没有再 bind @sandbox"
grep -q ' /storage/emulated/0/@sandbox ' "$MI" 2>/dev/null \
  && bad "旧 #SI2 缓存把 @sandbox 挂进了 mountinfo" \
  || ok "旧 #SI2 缓存没有把 @sandbox 挂进 mountinfo"
head -1 "$D51C/.conf.cache" 2>/dev/null | grep -q '^#SI3 ' \
  && ok "新缓存头为 #SI3（带解析器+修复脚本指纹）" \
  || bad "缓存头没有升级：$(head -1 "$D51C/.conf.cache" 2>/dev/null)"
grep -q '^|com.victim=1:@sandbox ' "$D51C/.conf.cache" 2>/dev/null \
  && bad "新缓存仍保留 @sandbox" || ok "新缓存按当前配置重建"

# ---------- 51d) 反例：同样的缓存内容用当前 #SI3 头会真的 bind @sandbox ----------
# 证明 51c 的“没有 bind”不是 grep 写错造成的假绿。
D51D=$T/data51d; seed_seen "$D51D" || exit 1
sandbox_ok_mi; setup_src || exit 1
mkdir -p "$SRC/0/@sandbox" "$D51D" || exit 1
cache_sig=$(cat scripts/si-config.awk scripts/fix-si-mounts.sh 2>/dev/null | sha256sum | awk '{print $1}')
printf '#SI3 %s %s\n' "$(stat -c '%y:%s' "$T/conf51c.json" 2>/dev/null)" "$cache_sig" > "$D51D/.conf.cache"
printf '|com.victim=1:@sandbox \n@PKGS com.victim\n' >> "$D51D/.conf.cache"
CONF_FILE=$T/conf51c.json; TEST_NOW=3300; TEST_MONO=7300
out=$(run_fix "$D51D" 0); r=$(result "$out")
CONF_FILE=$T/conf.json; TEST_NOW=""; TEST_MONO=""
grep -q ' /storage/emulated/0/@sandbox ' "$MI" 2>/dev/null \
  && ok "当前 #SI3 缓存确实会 bind @sandbox（51c 反例有效）" \
  || bad "当前 #SI3 缓存也没有 bind @sandbox，51c 断言不可信"

# ---------- 52) dry-run 不清理已有 old-format .sandbox_seen ----------
D52=$T/data52; mkdir -p "$D52"
printf 'com.victim\ncom.old|%s|mnt:[4026532001]\ncom.old2|%s||/0/Android/data/com.old2/sdcard\n' \
  "$TEST_BOOT" "$TEST_BOOT" > "$D52/.sandbox_seen"
cp -f "$D52/.sandbox_seen" "$T/seen52.bak" || exit 1
base_mi; setup_src || exit 1
out=$(run_fix "$D52" 1); r=$(result "$out")
cmp -s "$D52/.sandbox_seen" "$T/seen52.bak" \
  && ok "-n 不清理/不改写已有 old-format seen" || bad "-n 改写了 .sandbox_seen"
has "$r" 'checked=1' && ok "-n 仍完成扫描" || bad "-n 没完成扫描：$r"

# ---------- 53) 无 mount_dirs 的包不计 checked（checked 在 EN 过滤后） ----------
D53=$T/data53; mkdir -p "$D53"
cat > "$T/conf53.json" <<'J'
{"mount_dirs_templates":[{"id":"t1","list":["DCIM"]}],"apps":[{"package_name":"com.victim","enabled":true,"mount_dirs":true,"template_ids":["t1"]},{"package_name":"com.nodirs","enabled":true}]}
J
mkdir -p "$P/125" || exit 1
: > "$P/125/mountinfo"
base_mi; setup_src || exit 1
CONF_FILE=$T/conf53.json; PS_NODIRS=1
out=$(run_fix "$D53" 1); r=$(result "$out")
CONF_FILE=$T/conf.json; PS_NODIRS=0
has "$r" 'checked=1' && ok "无 mount_dirs 的包不算已隔离进程（checked=1）" \
  || bad "checked 把无配置的包算进去了：$r"
has "$r" 'sandbox_gone' && ok "com.victim 仍按丢失上报" || bad "com.victim 没上报：$r"
rm -rf "$P/125"

# ---------- 54) 退避只看单调时钟：系统时间跳变不改变退避 ----------
D54=$T/data54; seed_seen "$D54" || exit 1
base_mi; setup_src || exit 1
NS_HIDE_PREFIX="$SRC/0"; TEST_NOW=1000; TEST_MONO=5000
out=$(run_fix "$D54" 0); r=$(result "$out")
has "$r" 'sandbox_gone' && ok "时间跳变用例首轮失败" || bad "时间跳变用例首轮没失败：$r"
# 墙钟向前跳 20 年，单调只走 50 秒：仍应在 180 秒退避期里。
TEST_NOW=650000000; TEST_MONO=5050
out=$(run_fix "$D54" 0); r=$(result "$out")
has "$r" 'retry=130' && ok "墙钟前跳但单调未到期：retry 仍按单调剩余秒数" \
  || bad "墙钟跳变影响了退避：$r"
[ ! -s "$T/nsenter.log" ] && [ ! -s "$T/mount.log" ] \
  && ok "墙钟跳变期间不探测、不动挂载" || bad "墙钟跳变期间仍探测：$(cat "$T/nsenter.log" "$T/mount.log" 2>/dev/null)"
# 墙钟跳回，单调到期：允许重试。
TEST_NOW=900; TEST_MONO=5200
out=$(run_fix "$D54" 0); r=$(result "$out")
[ -s "$T/nsenter.log" ] && ok "单调时间到期后才重试（不受墙钟回跳影响）" \
  || bad "单调时间到期仍不退避"
NS_HIDE_PREFIX=""; TEST_NOW=""; TEST_MONO=""

# ---------- 55) 旧格式（只有墙钟）失败行不参与退避 ----------
D55=$T/data55; seed_seen "$D55" || exit 1
base_mi; setup_src || exit 1
printf '1000.000 com.victim /@sandbox failed ctx=0:50@testboot@%s\n' "$TEST_NS" > "$D55/.repairs"
TEST_NOW=1000; TEST_MONO=9000
out=$(run_fix "$D55" 0); r=$(result "$out")
TEST_NOW=""; TEST_MONO=""
has "$r" 'sandbox=1' && ok "旧格式失败行按无退避处理，沙箱照常重建" || bad "旧格式行挡住了重建：$r"
grep -q ' mono=9000' "$D55/.repairs" 2>/dev/null \
  && ok "新写入的 .repairs 行带单调时间戳" || bad "新行没有 mono 时间戳：$(cat "$D55/.repairs" 2>/dev/null)"

# ---------- 56) custom_dirs 里的 * 不展开 glob，照样补挂 ----------
D56=$T/data56; seed_seen "$D56" || exit 1
base_mi; setup_src || exit 1
cat > "$T/conf56.json" <<'J'
{"apps":[{"package_name":"com.victim","enabled":true,"mount_dirs":{"custom_dirs":["zz*g"]}}]}
J
mkdir -p "$SRC/0/Android/data/com.victim/sdcard/zz*g" "$SRC/0/zz*g" || exit 1
: > zzg   # 当前目录里造一个能被 zz*g 匹配的文件：老写法会把目录名展开成它
CONF_FILE=$T/conf56.json
out=$(run_fix "$D56" 0); r=$(result "$out")
CONF_FILE=$T/conf.json; rm -f zzg
has "$r" 'sandbox=1' && ok "* 目录用例仍重建沙箱" || bad "含 * 目录的沙箱没重建：$r"
grep -qF '/zz*g /storage/emulated/0/zz*g' "$T/mount.log" 2>/dev/null \
  && ok "含 * 的自定义目录按字面量补挂（未被 glob 展开）" \
  || bad "含 * 的目录没有补挂：$(cat "$T/mount.log" 2>/dev/null)"
grep -qF ' /0/zz*g /storage/emulated/0/zz*g ' "$MI" 2>/dev/null \
  && ok "fake mountinfo 出现含 * 的目标" || bad "含 * 的目标没有落到 mountinfo"

# ---------- 57) 锚点目录缺失：主扫描报 target_missing + broken，不 bind ----------
D57=$T/data57; seed_seen "$D57" || exit 1
sandbox_ok_mi; setup_src || exit 1
mkdir -p "$DATA/media/0/Android/data/com.victim/sdcard/Android/data" \
         "$DATA/media/0/Android/data/com.victim/sdcard/Android/media" \
         "$DATA/media/0/Android/data/com.victim/sdcard/Android/obb" || exit 1
rm -rf "$DATA/media/0/Android/data/com.victim/sdcard/DCIM"
out=$(run_fix "$D57" 0); r=$(result "$out")
has "$r" 'target_missing' && ok "锚点缺失报 skipped=target_missing" || bad "锚点缺失被静默跳过：$r"
has "$r" 'broken=1' && ok "锚点缺失计入 broken" || bad "锚点缺失没计入 broken：$r"
has "$r" 'fixed=0' && ok "锚点缺失不计 fixed" || bad "锚点缺失仍计 fixed：$r"
case "$out" in
  *"$DATA/media/0/Android/data/com.victim/sdcard/DCIM"*) ok "日志说明缺的是哪个目录" ;;
  *) bad "日志没写缺失目录：$out" ;;
esac
[ ! -s "$T/mount.log" ] && ok "锚点缺失时不 bind" || bad "锚点缺失仍 bind：$(cat "$T/mount.log")"
mkdir -p "$DATA/media/0/Android/data/com.victim/sdcard/DCIM"   # 复原，供后面的 T 路径用例

# ---------- 58) 锚点目录缺失：重建循环报 target_missing，沙箱仍重建 ----------
D58=$T/data58; seed_seen "$D58" || exit 1
base_mi; setup_src || exit 1
rm -rf "$SRC/0/Android/data/com.victim/sdcard/DCIM"
out=$(run_fix "$D58" 0); r=$(result "$out")
has "$r" 'target_missing' && ok "重建循环报 target_missing" || bad "重建循环静默跳过缺失锚点：$r"
has "$r" 'sandbox=1' && ok "缺失共享目录不影响重建沙箱根" || bad "缺共享目录导致沙箱没重建：$r"
has "$r" 'broken=1' && ok "重建循环的锚点缺失仍计入 broken" || bad "重建循环 broken 不对：$r"
case "$out" in
  *"$SRC/0/Android/data/com.victim/sdcard/DCIM"*) ok "重建日志说明缺的是哪个目录" ;;
  *) bad "重建日志没写缺失目录：$out" ;;
esac

# ---------- 59) 普通根 root=/0：回滚按原 root 挂回并校验 ----------
D59=$T/data59; seed_seen "$D59" || exit 1
base_mi
printf '103 100 0:50 /0 /storage/emulated/0 rw - fuse /dev/fuse rw\n' >> "$MI"
setup_src || exit 1
BIND_WRONG_SRC=1
out=$(run_fix "$D59" 0); r=$(result "$out")
BIND_WRONG_SRC=0
has "$out" '已把原 FUSE 根挂回' && ok "root=/0 回滚后挂回原根" || bad "root=/0 没挂回：$out"
grep -q ' 0:50 /0 /storage/emulated/0 ' "$MI" 2>/dev/null \
  && ok "挂回后 root 仍是原 root /0" || bad "挂回后 root 不是 /0：$(cat "$MI")"
has "$r" 'sandbox_gone' && ok "root=/0 回滚完成按 gone 上报" || bad "root=/0 回滚状态不对：$r"

# ---------- 60) 普通根 root=/0：恢复后 root 不符 → rollback，不谎报 ----------
D60=$T/data60; seed_seen "$D60" || exit 1
base_mi
printf '103 100 0:50 /0 /storage/emulated/0 rw - fuse /dev/fuse rw\n' >> "$MI"
setup_src || exit 1
BIND_WRONG_SRC=1; RESTORE_BAD_ROOT=1
out=$(run_fix "$D60" 0); r=$(result "$out")
BIND_WRONG_SRC=0; RESTORE_BAD_ROOT=0
has "$out" '原 FUSE 根恢复失败' && ok "恢复后 root 不符会报恢复失败" || bad "root 不符没报失败：$out"
has "$out" '已把原 FUSE 根挂回' && bad "root 不符却宣称已挂回：$out" || ok "root 不符不谎报已挂回"
has "$r" 'rollback' && ok "root 不符打 rollback tag" || bad "root 不符没有 rollback：$r"
has "$r" 'sandbox_stale' && ok "root 不符按 sandbox_stale 上报" || bad "root 不符没有报 stale：$r"

# ---------- 61) 普通根 root=/0：umount 未生效 → 不 restore ----------
D61=$T/data61; seed_seen "$D61" || exit 1
base_mi
printf '103 100 0:50 /0 /storage/emulated/0 rw - fuse /dev/fuse rw\n' >> "$MI"
setup_src || exit 1
UMOUNT_FAIL=3
out=$(run_fix "$D61" 0); r=$(result "$out")
UMOUNT_FAIL=0
has "$out" 'umount 未生效' && ok "root=/0 umount 未生效有明确日志" || bad "root=/0 日志没说明 umount 未生效：$out"
has "$out" '已把原 FUSE 根挂回' && bad "umount 未生效却尝试恢复原根：$out" || ok "umount 未生效不 restore"
[ ! -s "$T/mount.log" ] && ok "umount 未生效时没有 bind（含 restore）" || bad "umount 未生效仍 bind：$(cat "$T/mount.log")"
has "$r" 'sandbox_gone' && ok "root=/0 umount 未生效按 gone 上报" || bad "root=/0 状态不对：$r"
grep -q ' /0 /storage/emulated/0 ' "$MI" 2>/dev/null && ok "root=/0 普通根保持原样" || bad "root=/0 普通根被动了"

# ---------- 62) 扫描后进程变化（重建路径）：不 bind/umount，报 pid_changed ----------
D62=$T/data62; seed_seen "$D62" || exit 1
base_mi; setup_src || exit 1
mkproc 123 3000
mkstatline 123 4000 > "$T/stat.changed"
STAT_FLIP="$SRC/0/Android/data/com.victim/sdcard"; STAT_FILE=$P/123/stat
out=$(run_fix "$D62" 0); r=$(result "$out")
STAT_FLIP=""; STAT_FILE=""
mkproc 123 1000
has "$r" 'pid_changed' && ok "扫描后 starttime 变化 → skipped=pid_changed" || bad "进程变化被忽略：$r"
has "$r" 'fixed=0' && ok "进程变化时不计 fixed" || bad "进程变化仍计 fixed：$r"
has "$out" '进程已变化' && ok "日志说明进程已变化" || bad "日志没有进程变化说明：$out"
has "$r" 'sandbox=' && bad "进程变化仍报 sandbox=：$r" || ok "进程变化时不重建沙箱"
[ ! -s "$T/mount.log" ] && [ ! -s "$T/umount.log" ] \
  && ok "进程变化时不 bind/umount" || bad "进程变化仍动挂载：$(cat "$T/mount.log" "$T/umount.log" 2>/dev/null)"

# ---------- 63) 扫描后进程变化（T 路径）：不 bind/umount，报 pid_changed ----------
D63=$T/data63; seed_seen "$D63" || exit 1
sandbox_ok_mi; setup_src || exit 1
mkproc 123 3000
mkstatline 123 4000 > "$T/stat.changed"
STAT_FLIP="$SRC/0/DCIM"; STAT_FILE=$P/123/stat
out=$(run_fix "$D63" 0); r=$(result "$out")
STAT_FLIP=""; STAT_FILE=""
mkproc 123 1000
has "$r" 'pid_changed' && ok "T 路径扫描后变化 → skipped=pid_changed" || bad "T 路径进程变化被忽略：$r"
has "$r" 'fixed=0' && ok "T 路径进程变化不计 fixed" || bad "T 路径进程变化仍计 fixed：$r"
grep -q ' /storage/emulated/0/DCIM ' "$MI" 2>/dev/null \
  && bad "进程变化后仍挂上了 DCIM：$(cat "$MI")" || ok "进程变化后 DCIM 没有被挂上"
[ ! -s "$T/mount.log" ] && [ ! -s "$T/umount.log" ] \
  && ok "T 路径进程变化时不 bind/umount" || bad "T 路径进程变化仍动挂载"

echo
[ "$fail" = 0 ] && { echo "sandbox.test: PASS"; exit 0; }
echo "sandbox.test: FAIL"; exit 1
