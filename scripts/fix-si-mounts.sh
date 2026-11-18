#!/system/bin/sh
# fix-si-mounts.sh — 修复「存储空间隔离」丢失/挂错层的共享目录挂载；只补挂载，不改配置。
# 用法（root）：sh fix-si-mounts.sh [-n] [-q] [-v] [--trim-only]；末行 RESULT 供 daemon 解析。
# --trim-only 只裁剪状态文件、不扫描；FUSE 未就绪立即 defer=fuse（fail-closed），由 daemon 退避重试。

LC_ALL=C
export LC_ALL
# 系统 toybox ps 才支持 -o uid,etime；SI_TEST=1 时保留 PATH stub。
PS_BIN=ps
if [ "$SI_TEST" != 1 ] && [ -x /system/bin/ps ]; then PS_BIN=/system/bin/ps; fi
DRY=0; QUIET=0; VERBOSE=0; TRIM_ONLY=0
for a in "$@"; do
  case "$a" in
    -n|--dry-run) DRY=1 ;;
    -q|--quiet) QUIET=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    --trim-only) TRIM_ONLY=1 ;;
  esac
done
say() { [ "$QUIET" = 1 ] || echo "$@"; }
# 配置解析器与脚本同目录；缺失时 fail-closed（error=config），不退回旧正则。
case "$0" in */*) FIXDIR=${0%/*} ;; *) FIXDIR=. ;; esac
PARSER=$FIXDIR/si-config.awk
EXTRA_SKIP=""
# RESULT 行格式的唯一实现（与 tools 里的 fix stub 共用）；缺失时保留等价输出。
if [ -r "$FIXDIR/result.sh" ]; then . "$FIXDIR/result.sh"; fi
if ! command -v result_line >/dev/null 2>&1; then
  result_line() {
    _ro="RESULT checked=${1:-0} broken=${2:-0} fixed=${3:-0} young=${4:-0}"
    [ "$#" -ge 4 ] && shift 4
    for _rkv in "$@"; do _ro="$_ro $_rkv"; done
    printf '%s\n' "$_ro"
  }
fi

CONF=${SI_CONF:-/data/adb/storage-isolation/configuration.json}
# 自测用 SI_TEST=1 才把 /proc 换到 fixture，生产环境忽略残留变量。
PROC=/proc
if [ "$SI_TEST" = 1 ] && [ -n "$SI_PROC" ]; then
  PROC=$SI_PROC
fi
# 自测用 SI_TEST=1 才换 /data 与 FUSE 源前缀。
DATA_ROOT=/data
SRC_ROOT=/mnt/user/0/emulated
if [ "$SI_TEST" = 1 ]; then
  [ -n "$SI_TEST_DATA" ] && DATA_ROOT=$SI_TEST_DATA
  [ -n "$SI_TEST_SRC" ] && SRC_ROOT=$SI_TEST_SRC
fi
RC=${SI_DATA:-/data/adb/si-mount-fix}
if [ ! -d "$RC" ]; then
  mkdir -p "$RC" 2>/dev/null || {
    echo "无法写入 $RC" >&2
    result_line 0 0 0 0 error=datadir
    exit 3
  }
  chmod 700 "$RC" 2>/dev/null
fi
if [ ! -w "$RC" ]; then
  echo "无法写入 $RC" >&2
  result_line 0 0 0 0 error=datadir
  exit 3
fi

# MIN_AGE：daemon 用 SI_MIN_AGE 传入；手动执行（action/WebUI/终端）时读模块 config.conf。
if [ -z "${SI_MIN_AGE:-}" ] && [ -r "$RC/config.conf" ]; then
  SI_MIN_AGE=$(sed -n 's/^[[:space:]]*MIN_AGE[[:space:]]*=[[:space:]]*//p' "$RC/config.conf" 2>/dev/null \
    | head -1 | sed 's/#.*//' | tr -d ' \r')
fi
AGE_MIN=${SI_MIN_AGE:-15}
case "$AGE_MIN" in ''|*[!0-9]*) AGE_MIN=15 ;; esac
[ "$AGE_MIN" -lt 5 ] && AGE_MIN=5
[ "$AGE_MIN" -gt 120 ] && AGE_MIN=120

# 纯 shell 取 epoch 秒（btime+uptime，不 fork date）；读不到退回 date，只影响熔断时间窗。
get_now() {
  _bt=""; _up=""
  if [ -r /proc/stat ]; then
    while read -r _k _v _; do
      [ "$_k" = "btime" ] && { _bt=$_v; break; }
    done < /proc/stat 2>/dev/null
  fi
  if [ -r /proc/uptime ]; then
    read -r _up _ < /proc/uptime 2>/dev/null
    _up=${_up%%.*}
  fi
  case "$_bt$_up" in
    ''|*[!0-9]*) NOW=$(date +%s 2>/dev/null) ;;
    *) NOW=$((_bt + _up)) ;;
  esac
  case "$NOW" in ''|*[!0-9]*) NOW=0 ;; esac
}
NOW=""
set_now() {
  if [ "$SI_TEST" = 1 ] && [ -n "$SI_TEST_NOW" ]; then
    NOW=$SI_TEST_NOW
  else
    get_now
  fi
}
set_now
# 失败退避用单调时钟：/proc/uptime 不随系统时间跳变走；读不到时按 0（不做退避）。
MONO=""
set_mono() {
  MONO=""
  if [ "$SI_TEST" = 1 ] && [ -n "$SI_TEST_MONO" ]; then
    MONO=$SI_TEST_MONO
  elif [ -r /proc/uptime ]; then
    read -r MONO _ < /proc/uptime 2>/dev/null
    MONO=${MONO%%.*}
  fi
  case "$MONO" in ''|*[!0-9]*) MONO=0 ;; esac
}
set_mono
REP=$RC/.repairs
CH=$RC/.churn
# 沙箱重建失败退避用的内部键。故意以 / 开头：dir_tag 拒绝绝对路径，
# 用户自定义目录不可能和它撞键（合法的 @sandbox 仍是普通目录）。
SAND_KEY='/@sandbox'
# Android isolated 子进程的 uid 区间：这类进程不是 SI 的隔离对象（没有 /storage），
# 扫描与重建路径共用同一组边界，避免两处各写一份数字漂移。
ISO_UID_MIN=90000
ISO_UID_MAX=99999
# 修复失败后的每包退避：120~300s 区间内取 180s；dev/boot/ns 变化会立即失效。
SB_BACKOFF=180
CACHE=$RC/.conf.cache
CACHE_USE=$CACHE
SRC=$RC/.si-conf.$$
PARSED=$RC/.si-parsed.$$
OUTF=$RC/.si-out.fix
FIXED_LIST=$RC/.si-fixed.$$
[ "$DRY" = 1 ] && OUTF=$RC/.si-out.dry.$$
CLEAN_LOCK=""
# 曾经识别到合法沙箱的包（重建资格证据，不随 trim 删除，只限 200 行）；
# .fuse_dev 只记录本轮 FUSE 设备号，供排障，不作为重建依据。
SANDBOX_SEEN=$RC/.sandbox_seen
FUSE_DEV=$RC/.fuse_dev
SAND_REPORT=$RC/.sandbox_report
SEEN_TMP=$RC/.si-seen.$$
SEEN_LIST=""
SEEN_N=0

# <1 秒熔断判据要毫秒；只有已有 .repairs/.churn 时才多一次 date，健康首扫不 fork。
NOW_MS=0
if [ "$SI_TEST" = 1 ] && [ -n "$SI_TEST_NOW" ]; then
  NOW_MS="${NOW}000"  # 用字符串拼接：mksh 的算术是 32 位，NOW*1000 会溢出成负数
elif [ -s "$REP" ] || [ -s "$CH" ]; then
  NOW_MS=$(date +%s%3N 2>/dev/null)
fi
case "$NOW_MS" in ''|*[!0-9]*) NOW_MS="${NOW}000" ;; esac

cleanup() {
  # 只删自己的锁：锁可能被判陈旧后重抢，别删别人的。
  if [ -n "$CLEAN_LOCK" ] && [ "$(cat "$CLEAN_LOCK/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$CLEAN_LOCK" 2>/dev/null
  fi
  # 固定输出文件保留（下一轮覆盖），只清带 PID 的临时文件；dry-run 也带 PID 以免并发覆盖。
  rm -f "$PARSED" "$SRC" "$FIXED_LIST" "$FIXED_LIST.tmp" "$FIXED_LIST.bak.$$" "$SEEN_TMP" "$CACHE.tmp.$$" "$REP.tmp.$$" "$REP.bak.$$" "$CH.tmp.$$" 2>/dev/null
  [ "$DRY" = 1 ] && [ -e "$OUTF" ] && rm -f "$OUTF" 2>/dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

# 带 PID 的临时文件只按“PID 已退出或明显过期”清理：-n 不持锁，盲删会踩到
# 正在扫描的那一轮（它正在写 .si-conf.$$ / .si-out.dry.$$）。
TRIM_TMP_AGE=1800
trim_tmp() {   # 参数是待检查的临时文件；未匹配的 glob 会原样传进来
  for _tt in "$@"; do
    [ -e "$_tt" ] || continue
    _ttp=${_tt##*.}
    if [ -n "$_ttp" ] && [ -d "$PROC/$_ttp" ]; then
      # PID 还活着：只有文件确实过期才删。
      _ttm=$(stat -c %Y "$_tt" 2>/dev/null)
      case "$NOW$_ttm" in ''|*[!0-9]*) continue ;; esac
      [ $((NOW - _ttm)) -gt "$TRIM_TMP_AGE" ] || continue
    fi
    rm -f "$_tt" 2>/dev/null
  done
}

trim_state() {
  # .repairs 只留最近 1 小时/200 行；.churn 是进程内状态，重启清零（否则一次抖动永久 block）。
  if [ -s "$REP" ]; then
    awk -v now="$NOW" '
      { if (($1 + 0) >= now - 3600) b[++n] = $0 }
      END { s = n - 199; if (s < 1) s = 1; for (i = s; i <= n; i++) print b[i] }
    ' "$REP" > "$REP.tmp.$$" 2>/dev/null && mv -f "$REP.tmp.$$" "$REP" 2>/dev/null
  fi
  rm -f "$CH" 2>/dev/null
  trim_tmp "$RC"/.si-out.dry.* "$RC"/.si-conf.* "$RC"/.si-parsed.* "$RC"/.conf.cache.tmp.* \
           "$RC"/.si-fixed.* "$RC"/.si-seen.*
  rm -f "$RC"/.si-allow.* "$RC"/.si-cand.* "$RC"/.si-ps.* 2>/dev/null
}

if [ "$DRY" = 0 ]; then
  LOCK=$RC/.si-fix.lock
  if ! mkdir "$LOCK" 2>/dev/null; then
    lp=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -z "$lp" ]; then
      # 另一个进程刚 mkdir、还没写 pid：给 1 秒，别把活锁当陈旧锁抢掉。
      i=0
      while [ "$i" -lt 10 ]; do
        sleep 0.1 2>/dev/null || sleep 1
        lp=$(cat "$LOCK/pid" 2>/dev/null)
        [ -n "$lp" ] && break
        i=$((i + 1))
      done
    fi
    if [ -n "$lp" ] && [ -d "$PROC/$lp" ] && \
       tr '\0' ' ' < "$PROC/$lp/cmdline" 2>/dev/null | grep -q 'fix-si-mounts\.sh'; then
      result_line 0 0 0 0 skipped=locked
      exit 0
    fi
    rm -rf "$LOCK" 2>/dev/null
    if ! mkdir "$LOCK" 2>/dev/null; then
      # 不是“另一轮在跑”（pid 已失效/锁刚被清），而是数据目录写不了：
      # 必须给出 RESULT，不能让 action/WebUI 把空输出当成“没有需要修复”。
      echo "无法创建锁目录 $LOCK" >&2
      result_line 0 0 0 0 error=datadir
      exit 3
    fi
  fi
  echo $$ > "$LOCK/pid"
  CLEAN_LOCK=$LOCK
fi

if [ "$TRIM_ONLY" = 1 ]; then
  # 与 fix 共用同一把锁：有修复在跑时只跳过，不和 append 竞态。
  trim_state
  exit 0
fi

# 本 boot 标识：seen 证据只在同一 boot 内作为重建资格，避免关机前“曾隔离”在
# 用户关掉 SI 后被拿来强挂旧沙箱。
BOOT_ID=""
if [ "$SI_TEST" = 1 ] && [ -n "$SI_TEST_BOOT" ]; then
  BOOT_ID=$SI_TEST_BOOT
elif [ -r /proc/sys/kernel/random/boot_id ]; then
  read -r BOOT_ID < /proc/sys/kernel/random/boot_id 2>/dev/null
fi
if [ -z "$BOOT_ID" ] && [ -r /proc/stat ]; then
  while read -r _bk _bv _; do
    [ "$_bk" = "btime" ] && { BOOT_ID=$_bv; break; }
  done < /proc/stat 2>/dev/null
fi
case "$BOOT_ID" in ''|*[!A-Za-z0-9_.-]*) BOOT_ID=0 ;; esac

# .sandbox_seen：每行 pkg|boot|mnt_ns|uid|starttime|SB（“曾经识别到合法沙箱”的证据）。
# uid 与 /proc/<pid>/stat 第 22 字段 starttime 是匹配键的一部分：内核会把同一个
# ns inode 回收复用给别的进程，只按 pkg+boot+ns 匹配会把 isolated 子进程误当成
# “主进程曾经隔离过”。同 pkg 同 boot 同 ns 同 uid/start 只保留一条（SB 变化时更新）；
# 最多 200 行保留最近。旧版本（4 段及更少）的行没有 uid/start 指纹，按“无证据”处理，
# 由“源存在 + 属主匹配”的回落兜底，不能因此放过真实丢失。
load_seen() {
  SEEN_LIST=""; SEEN_N=0
  [ -r "$SANDBOX_SEEN" ] || return 0
  # 更早版本留下的是 pkg / pkg|ns|SB 格式，上一版留下的是 pkg|boot|ns|SB 四段格式：
  # 都不是六段（没有 uid/starttime 指纹），直接忽略（无证据）。
  awk -F'|' 'NF == 6 && $3 != "" && $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ && $6 != ""' \
    "$SANDBOX_SEEN" > "$SEEN_TMP" 2>/dev/null || return 0
  while IFS= read -r _sl; do
    [ -n "$_sl" ] || continue
    SEEN_LIST="$SEEN_LIST $_sl"
    SEEN_N=$((SEEN_N + 1))
  done 2>/dev/null < "$SEEN_TMP"
  # 非 dry-run 才回写清洗旧格式行（-n 必须只读；写文件前的锁在 DRY=0 时才持有）。
  if [ "$DRY" = 0 ]; then
    _so=$(wc -l < "$SANDBOX_SEEN" 2>/dev/null)
    _sv=$(wc -l < "$SEEN_TMP" 2>/dev/null)
    case "$_so$_sv" in *[!0-9]*) : ;; *) [ "$_so" != "$_sv" ] && mv -f "$SEEN_TMP" "$SANDBOX_SEEN" 2>/dev/null ;; esac
  fi
  rm -f "$SEEN_TMP" 2>/dev/null
}
seen_match() {   # pkg ns uid starttime（只看本 boot；uid/start 防止同一个 ns inode 被复用后假命中）
  [ -n "$3" ] || return 1
  [ -n "$4" ] || return 1
  _sm_pfx=" $1|$BOOT_ID|$2|$3|$4|"
  case " $SEEN_LIST " in *"$_sm_pfx"*) return 0 ;; esac
  return 1
}
seen_sb() {      # pkg ns -> 本 boot 记录的 SB（只作探测路径提示；可用性仍由 sandbox_probe 校验）
  _ss_pkg=$1; _ss_ns=$2
  for _se in $SEEN_LIST; do
    _eifs=$IFS; IFS='|'; set -- $_se; IFS=$_eifs
    if [ "${1:-}" = "$_ss_pkg" ] && [ "${2:-}" = "$BOOT_ID" ] && [ "${3:-}" = "$_ss_ns" ]; then
      printf '%s\n' "${6:-}"
      return 0
    fi
  done
  return 1
}
seen_add() {     # pkg ns sb uid starttime；正常情况下只 append，不整文件重写
  _sa=$1; _sn=$2; _ss=$3; _su=$4; _sst=$5
  case "$_sa" in ''|*[!A-Za-z0-9_.-]*) return 0 ;; esac
  # ns 读不到（进程刚退出）时不落盘：空 ns 行以后既匹配不上，也永远清不掉。
  [ -n "$_sn" ] || return 0
  case "$_ss" in ''|*[!A-Za-z0-9_./-]*) return 0 ;; esac
  # uid/starttime 是重建资格的匹配键：读不到就不落盘，避免下次拿残缺行误命中。
  case "$_su" in ''|*[!0-9]*) return 0 ;; esac
  case "$_sst" in ''|*[!0-9]*) return 0 ;; esac
  _pfx="$_sa|$BOOT_ID|$_sn|$_su|$_sst|"
  _old=""; _found=0
  for _se in $SEEN_LIST; do
    case "$_se" in "$_pfx"*) _old=${_se#"$_pfx"}; _found=1 ;; esac
  done
  [ "$_found" = 1 ] && [ "$_old" = "$_ss" ] && return 0
  _new="$_pfx$_ss"
  if [ "$_found" = 0 ]; then
    printf '%s\n' "$_new" >> "$SANDBOX_SEEN" 2>/dev/null || return 0
    SEEN_LIST="$SEEN_LIST $_new"
    SEEN_N=$((SEEN_N + 1))
  else
    # 同 pkg/boot/ns 的 SB 变了：少见，重建一次列表和文件。
    _list=""; _n=0
    for _se in $SEEN_LIST; do
      case "$_se" in "$_pfx"*) _list="$_list $_new" ;; *) _list="$_list $_se" ;; esac
      _n=$((_n + 1))
    done
    SEEN_LIST=$_list; SEEN_N=$_n
    { for _se in $SEEN_LIST; do printf '%s\n' "$_se"; done; } > "$SEEN_TMP" 2>/dev/null \
      && mv -f "$SEEN_TMP" "$SANDBOX_SEEN" 2>/dev/null || return 0
  fi
  if [ "$SEEN_N" -gt 200 ]; then
    tail -n 200 "$SANDBOX_SEEN" > "$SEEN_TMP" 2>/dev/null \
      && mv -f "$SEEN_TMP" "$SANDBOX_SEEN" 2>/dev/null
    load_seen
  fi
}
# -n 只读：把本轮 K 证据登记到内存 SEEN_LIST（不落盘），让 dry-run 与真跑用同一套
# “是否有 seen 证据”判断。真跑会先写盘，同一轮后面的 G 立刻能匹配到。
seen_mem_add() {   # pkg ns sb uid start
  case "$1" in ''|*[!A-Za-z0-9_.-]*) return 0 ;; esac
  [ -n "$2" ] || return 0
  case "$3" in ''|*[!A-Za-z0-9_./-]*) return 0 ;; esac
  case "$4" in ''|*[!0-9]*) return 0 ;; esac
  case "$5" in ''|*[!0-9]*) return 0 ;; esac
  SEEN_LIST="$SEEN_LIST $1|$BOOT_ID|$2|$4|$5|$3"
}
load_seen
[ "$DRY" = 0 ] && : > "$SAND_REPORT" 2>/dev/null
ns_of() { readlink "$PROC/$1/ns/mnt" 2>/dev/null; }
seen_any() {  # pkg 有任何 boot 的有效 seen 行
  case " $SEEN_LIST " in *" $1|"*) return 0 ;; esac
  return 1
}
seen_cur_boot_any() {  # pkg 在本 boot 任意 ns 有 seen 行
  _scb_pkg=$1
  for _se in $SEEN_LIST; do
    _eifs=$IFS; IFS='|'; set -- $_se; IFS=$_eifs
    if [ "${1:-}" = "$_scb_pkg" ] && [ "${2:-}" = "$BOOT_ID" ]; then
      return 0
    fi
  done
  return 1
}
# 重建资格：同 pkg 同 ns 同 uid/starttime 的 seen 直接通过；否则按“源存在+属主匹配”回落。
# 只有该包“只剩别的 boot 的旧行、本 boot 一行都没有”时才拒绝兜底；
# 本 boot 有任意 ns 行（应用重启换了 ns）就允许回落，是否拆普通根由 R4 门另行判断。
sandbox_eligible() {   # pid uid pkg ns
  # seen 里存的是扫描时刻的真实 uid/starttime：优先用 /proc 现值比对，
  # 读不到时才用 ps 给的 uid（极少数 ps 与 status 不一致的场景保持旧行为）。
  _se_uid=$(pid_real_uid "$1")
  [ -n "$_se_uid" ] || _se_uid=$2
  _se_start=$(pid_starttime "$1")
  seen_match "$3" "$4" "$_se_uid" "$_se_start" && return 0
  if seen_any "$3" && ! seen_cur_boot_any "$3"; then
    return 1
  fi
  sandbox_pick "$1" "$2" "$3" "$4" 0 >/dev/null 2>&1
  _se_rc=$?
  [ "$_se_rc" -eq 0 ] || [ "$_se_rc" -eq 2 ]
}

bind_mount() {   # pid src tgt（</dev/null：别吃掉调用方 while read 的 stdin）
  timeout 3 nsenter -t "$1" -m -- mount --bind "$2" "$3" </dev/null 2>&1 && return 0
  timeout 3 nsenter -t "$1" -m sh -c 'mount --bind "$1" "$2"' _ "$2" "$3" </dev/null 2>&1
}
umount_one() {   # pid tgt
  timeout 2 nsenter -t "$1" -m -- umount -l "$2" </dev/null 2>&1 && return 0
  timeout 2 nsenter -t "$1" -m umount -l "$2" </dev/null 2>&1
}
stat_of() {      # mountinfo target -> "dev count"
  awk -v t="$1" '$5==t {d=$3; n++} END {print d, n+0}' "$mi" 2>/dev/null
}
stat_src_of() {  # mountinfo target -> "dev count source"
  awk -v t="$1" '$5==t {d=$3; s=$4; n++} END {print d, n+0, s}' "$mi" 2>/dev/null
}
pid_starttime() {  # pid -> /proc/<pid>/stat 第 22 字段（进程启动时刻）
  awk '{ sub(/^.*\) /, ""); if (NF >= 20) print $20; exit }' "$PROC/$1/stat" 2>/dev/null
}
pid_real_uid() {   # pid -> /proc/<pid>/status 里的真实 uid
  awk '/^Uid:/ { print $2; exit }' "$PROC/$1/status" 2>/dev/null
}
# 扫描时记的 pid_start/pid_uid/pid_ns 与当前值不一致（进程重启、换 namespace、
# pid 被复用）就返回 1，调用方不得再对它 bind/umount。
pid_check() {
  _pc_pid=$1
  [ -n "${pid_start:-}" ] && [ -n "${pid_uid:-}" ] && [ -n "${pid_ns:-}" ] || return 1
  [ "$(pid_starttime "$_pc_pid")" = "$pid_start" ] || return 1
  [ "$(pid_real_uid "$_pc_pid")" = "$pid_uid" ] || return 1
  [ "$(ns_of "$_pc_pid")" = "$pid_ns" ] || return 1
  return 0
}
target_action_shell() {  # target -> b/0/r/s，与主扫描 target_action 一致
  set -- $(stat_src_of "$1"); _ta_d=${1:-}; _ta_n=${2:-0}
  if [ "$_ta_n" -eq 0 ]; then printf 'b\n'
  elif [ "$_ta_d" = "$FUSEDEV" ] && [ "$_ta_n" = 1 ]; then printf '0\n'
  elif [ "$_ta_d" = "$FUSEDEV" ]; then printf 'r\n'
  else printf 's\n'
  fi
}
sandbox_owner() {  # path -> uid；SI_TEST_UID 只给测试构造“属主不符”
  if [ "$SI_TEST" = 1 ] && [ -n "$SI_TEST_UID" ]; then
    printf '%s\n' "$SI_TEST_UID"
  else
    stat -c '%u' "$1" 2>/dev/null
  fi
}
sandbox_owner_ns() {  # pid path -> 应用 namespace 里的 uid
  if [ "$SI_TEST" = 1 ] && [ -n "$SI_TEST_UID" ]; then
    printf '%s\n' "$SI_TEST_UID"
  else
    timeout 2 nsenter -t "$1" -m -- stat -c '%u' "$2" </dev/null 2>/dev/null
  fi
}
sandbox_src_match() {  # src id
  case "$1" in
    */Android/data/"$2"/sdcard|*/Android/data/"$2"/cache/sdcard) return 0 ;;
  esac
  return 1
}
sb_to_src() {  # mountinfo root(SB) -> FUSE 源路径
  case "$1" in
    /media/*) printf '%s/%s\n' "$SRC_ROOT" "${1#/media/}" ;;
    /*)       printf '%s/%s\n' "$SRC_ROOT" "${1#/}" ;;
    *)        printf '%s/%s\n' "$SRC_ROOT" "$1" ;;
  esac
}
sand_report() {  # tag pkg [extra]（只写非 dry；daemon 读；extra 给 gone/na 带 pid/uid/ns/reason）
  [ "$DRY" = 1 ] && return 0
  if [ -n "${3:-}" ]; then
    printf '%s %s %s\n' "$1" "$2" "$3" >> "$SAND_REPORT" 2>/dev/null
  else
    printf '%s %s\n' "$1" "$2" >> "$SAND_REPORT" 2>/dev/null
  fi
}
allow_of() {     # pkg -> 配置缓存里的 allow 目录（缓存键里的 . 被转义过）
  [ -s "$CACHE_USE" ] || return 0
  awk -F'|' -v want="$1" '
    function unesc(s) { gsub(/\\\./, ".", s); return s }
    /^\|/ {
      i = index($0, "=")
      if (i < 3) next
      if (unesc(substr($0, 2, i - 2)) != want) next
      v = substr($0, i + 1)
      sub(/^[^:]*:/, "", v)
      print v
      exit
    }
  ' "$CACHE_USE" 2>/dev/null
}

# 配置缓存按 mtime:size 失效；解析统一走 scripts/si-config.awk（与 list-apps 共用）。
# 旧实现按行 split + 正则扫整条记录，真正的多行 JSON 会漏记录，嵌套 mount_dirs
# 也只能靠碰巧命中；新解析器切 JSON 结构，缓存层只做格式转换，不再二次猜语义。
cache_ok=0
CONF_STAT=$(stat -c '%y:%s' "$CONF" 2>/dev/null)
# 缓存头带解析器+修复脚本指纹：两者任一更新，旧缓存都自动失效。版本号从 SI2 升到
# SI3，同时让上个版本留下的 .conf.cache 不再被信任（旧缓存里可能还写着旧目录列表）。
CACHE_VER='#SI3'
PARSER_SIG=$(cat "$PARSER" "$0" 2>/dev/null | sha256sum | awk '{print $1}')
case "$PARSER_SIG" in ''|*[!0-9a-f]*) PARSER_SIG=0 ;; esac
if [ -s "$CACHE" ] && [ -n "$CONF_STAT" ]; then
  read -r chdr < "$CACHE" 2>/dev/null
  [ "$chdr" = "$CACHE_VER $CONF_STAT $PARSER_SIG" ] && cache_ok=1
fi

if [ "$cache_ok" = 0 ]; then
  META1=$(stat -c '%y:%s' "$CONF" 2>/dev/null)
  if ! cp -f "$CONF" "$SRC" 2>/dev/null || [ ! -s "$SRC" ]; then
    say "配置不可读，跳过本轮"
    result_line 0 0 0 0 error=config
    exit 2
  fi
  last=$(tr -d ' \t\r\n' < "$SRC" 2>/dev/null | tail -c 1)
  if [ "$last" != "}" ]; then
    say "配置不完整（SI 正在重写？），跳过本轮"
    result_line 0 0 0 0 error=config
    exit 2
  fi
  if [ ! -r "$PARSER" ]; then
    say "配置解析器缺失（$PARSER），跳过本轮"
    result_line 0 0 0 0 error=config
    exit 2
  fi
  if ! timeout 20 awk -f "$PARSER" "$SRC" > "$PARSED" 2>/dev/null; then
    say "配置解析失败（JSON 结构不支持？），跳过本轮"
    result_line 0 0 0 0 error=config
    exit 2
  fi

  # 预扫描：有无法表示的目录/未知模板时只打标签，由后面的 skipped 汇总上报。
  if grep -q '^X|' "$PARSED" 2>/dev/null; then
    xtags=$(sed -n 's/^X|[^|]*|\([a-z_]*\)|.*/\1/p' "$PARSED" 2>/dev/null | sort -u | tr '\n' ' ')
    EXTRA_SKIP="$EXTRA_SKIP $xtags"
    say "警告：目录名无法安全表示，已跳过（$xtags）"
  fi
  if grep -q '^W|' "$PARSED" 2>/dev/null; then
    wtags=$(sed -n 's/^W|[^|]*|\([a-z_]*\)|.*/\1/p' "$PARSED" 2>/dev/null | sort -u | tr '\n' ' ')
    EXTRA_SKIP="$EXTRA_SKIP $wtags"
    say "警告：模板里的目录名无法安全表示，已跳过（$wtags）"
  fi
  if grep -q '^U|' "$PARSED" 2>/dev/null; then
    EXTRA_SKIP="$EXTRA_SKIP template"
    say "警告：配置里有未知模板 id，已跳过（skipped=template）"
  fi

  printf '%s %s %s\n' "$CACHE_VER" "$META1" "$PARSER_SIG" > "$CACHE.tmp.$$" 2>/dev/null || {
    say "配置缓存写入失败，跳过本轮"
    result_line 0 0 0 0 error=config
    exit 2
  }
  # Q→进程匹配集合（shared- 同时登记去掉前缀的别名）；P→en/allow；D→目录。
  # 目录已在解析器里校验，这里只按空格拼接，不重做语义判断。
  awk -F'|' '
    function esc(s) { gsub(/\./, "\\.", s); return s }
    function addp(s) {
      s = esc(s)
      if (!(s in SEEN)) { SEEN[s] = 1; pkgs = pkgs (pkgs == "" ? "" : "|") s }
    }
    function flush() {
      if (cur == "") return
      # 旧缓存 allow 末尾带一个空格，主扫描的 A 行输出依赖这个格式；保持逐字兼容。
      if (allow != "") allow = allow " "
      print "|" cur "=" en ":" allow
      if (cur ~ /^shared-/) { r = cur; sub(/^shared-/, "", r); print "|" r "=" en ":" allow }
      cur = ""
    }
    $1 == "Q" { addp($2); if ($2 ~ /^shared-/) { r = $2; sub(/^shared-/, "", r); addp(r) } next }
    $1 == "P" { flush(); cur = $2; en = $3; allow = ""; next }
    $1 == "D" { if ($2 == cur) allow = allow (allow == "" ? "" : " ") $3; next }
    END { flush(); if (pkgs == "") pkgs = "@none"; print "@PKGS " pkgs }
  ' "$PARSED" >> "$CACHE.tmp.$$" 2>/dev/null || {
    rm -f "$CACHE.tmp.$$" 2>/dev/null
    say "配置缓存生成失败，跳过本轮"
    result_line 0 0 0 0 error=config
    exit 2
  }
  META2=$(stat -c '%y:%s' "$CONF" 2>/dev/null)
  if [ -n "$META1" ] && [ -n "$META2" ] && [ "$META1" != "$META2" ]; then
    rm -f "$CACHE.tmp.$$" 2>/dev/null
    say "配置在解析期间被改写，跳过本轮"
    result_line 0 0 0 0 error=config
    exit 2
  fi
  if [ "$DRY" = 1 ] || [ -z "$META1" ] || [ -z "$META2" ]; then
    # 体检或 stat 不可用：只读临时解析结果，不落缓存。
    CACHE_USE=$CACHE.tmp.$$
  else
    if ! mv -f "$CACHE.tmp.$$" "$CACHE" 2>/dev/null; then
      say "配置缓存写入失败，跳过本轮"
      result_line 0 0 0 0 error=config
      exit 2
    fi
  fi
fi

# 不在这里阻塞等 FUSE：设备号由主 awk 顺带读取，取不到立即 defer=fuse，
# 由 daemon 在开机宽限期内退避重试；不占 fix 的 timeout 预算。
# 宿主基准必须用 init 的 mount namespace；模块自己的 ns 可能滞后。
HOSTMI=$PROC/1/mountinfo
if [ ! -r "$HOSTMI" ] && [ "$SI_TEST" = 1 ]; then
  HOSTMI=$PROC/self/mountinfo
fi

"$PS_BIN" -A -o pid,uid,etime,args 2>/dev/null | awk -v cache="$CACHE_USE" -v proc="$PROC" \
    -v now="$NOW" -v nowms="$NOW_MS" -v amin="$AGE_MIN" -v verbose="$VERBOSE" -v dry="$DRY" \
    -v rep="$REP" -v ch="$CH" -v dataroot="$DATA_ROOT" -v hostmi="$HOSTMI" \
    -v isomin="$ISO_UID_MIN" -v isomax="$ISO_UID_MAX" '
  function secs(e,  p,n,t,d) {
    d = 0
    if (index(e, "-") > 0) { split(e, p, "-"); d = p[1] + 0; e = p[2] }
    n = split(e, t, ":")
    if (n == 3) return d * 86400 + t[1] * 3600 + t[2] * 60 + t[3]
    if (n == 2) return d * 86400 + t[1] * 60 + t[2]
    return d * 86400 + t[1]
  }
  function parse_mi(l,  f,n,i,_ft) {
    # 大多数 mountinfo 行无关，先用 C 级 substring 过滤再 split。
    if (index(l, "/storage/emulated") == 0 && index(l, "/Android/data/") == 0 \
        && index(l, "/mnt/user/0/emulated") == 0) return
    n = split(l, f, " ")
    if (f[5] == "/storage/emulated" || f[5] == "/mnt/user/0/emulated") {
      _ft = ""
      for (i = 7; i <= n; i++) if (f[i] == "-") { _ft = f[i + 1]; break }
      if (f[5] == "/storage/emulated") { APP_S = f[3]; APP_SFT = _ft }
      else { APP_M = f[3]; APP_MFT = _ft }
    }
    if (f[5] == "/storage/emulated/0") { TROOT = f[4]; TN++ }
    if (f[4] ~ /^\/(media\/)?[0-9]+\/Android\/data\/.+\/(cache\/)?sdcard$/ && f[5] ~ /^\/storage\/emulated\/[0-9]+$/) {
      SB = f[4]; SDEV = f[3]; MP = f[5]; SFT = ""
      # fstype 在 " - " 分隔符之后；只有 fuse 沙箱才可能是“旧 FUSE 僵死”。
      for (i = 7; i <= n; i++) if (f[i] == "-") { SFT = f[i + 1]; break }
    }
    if (f[5] ~ /^\/storage\/emulated\/[0-9]+\//) {
      TD[f[5]] = f[3]; TC[f[5]]++
    }
  }
  function target_action(t) {
    if (!(t in TC)) return "b"
    if (TD[t] == SDEV && TC[t] == 1) return "0"
    if (TD[t] == SDEV) return "r"
    return "s"
  }
  function churn_decide(k,  n,last,d) {
    if (!(k in CHS)) {
      n = FIXN[k] + 0; last = LAST[k] + 0
      if (n >= 3 || (n >= 1 && nowms - last < 1000)) {
        CHURN++; RETRY_IN = 600
        return "churn-new"
      }
      return "repair"
    }
    if (CHS[k] == "block") {
    if (now + 0 < CHU[k] + 0) { CHURN++; return "churn" }
    return "retry"
  }
    if (now + 0 < CHU[k] + 0) {
      CHURN++
      d = CHU[k] - now
      if (RETRY_IN == 0 || d < RETRY_IN) RETRY_IN = d
      return "churn"
    }
    return "retry"
  }
  # 同包多 PID 会各报一次目标状态：健康只登记 CAND，本轮同 key 只要出现
  # b/r/churn/retry/s 任一动作就 BADK；END 时只清没被 BADK 的 churn。
  function note_target(k, p, n, a) {
    if (a == "0") {
      if (k in CHS) { CAND[k] = 1; CPKG[k] = p; CTGT[k] = n }
      return
    }
    if (a == "b" || a == "r" || a == "churn" || a == "retry" || a == "s") BADK[k] = 1
  }
  BEGIN {
    checked = 0; young = 0; CHURN = 0; RETRY_IN = 0
    FUSE_BAD = 0; BAD_CFG = 0
    FDEV = ""; HOSTM = ""
    # 宿主基准只认 init 的 /mnt/user/0/emulated：vold 重挂的是它，init 的
    # /storage/emulated 往往只是旧 FUSE 的 bind，不能当基准；其设备号也排除在
    # HOSTDEV 外，否则旧沙箱会被误判成“还在宿主里”（layer 而不是 stale）。
    while ((getline l < hostmi) > 0) {
      split(l, z, " ")
      if (z[3] != "" && z[5] != "/storage/emulated" && index(z[5], "/storage/emulated/") != 1) HOSTDEV[z[3]] = 1
      if (z[5] == "/mnt/user/0/emulated" && HOSTM == "") { HOSTM = z[3]; FDEV = z[3] }
    }
    close(hostmi)
    if (FDEV == "") { print "F|"; FUSE_BAD = 1; exit 9 }
    print "F|" FDEV "|" HOSTM
    while ((getline l < cache) > 0) {
      if (l ~ /^@PKGS /) { pkgs = substr(l, 7); continue }
      if (l ~ /^\|/) {
        i = index(l, "=")
        if (i < 3) continue
        key = substr(l, 2, i - 2)
        if (!(key in EN)) EN[key] = substr(l, i + 1)
      }
    }
    close(cache)
    if (pkgs == "") { BAD_CFG = 1; exit 5 }
    while ((getline l < rep) > 0) {
      split(l, a, " ")
      if (a[4] == "fixed" && a[1] + 0 >= now - 300 && a[1] + 0 <= now + 5) {
        k = a[2] SUBSEP a[3]
        FIXN[k]++
        _lms = int(a[1] * 1000)
        if (_lms > LAST[k]) LAST[k] = _lms
      }
    }
    close(rep)
    while ((getline l < ch) > 0) {
      split(l, a, "|")
      if (a[1] == "" || a[2] == "") continue
      k = a[1] SUBSEP a[2]
      CHS[k] = a[4]; CHU[k] = a[3] + 0
    }
    close(ch)
  }
  {
    if (NR == 1) next
    line = $0
    sub(/^[ \t]+/, "", line)
    n = split(line, a, /[ \t]+/)
    if (n < 4) next
    pid = a[1]; uid = a[2]; et = a[3]; pkg = a[4]
    if (pid !~ /^[0-9]+$/) next
    # Android isolated 子进程（uid 90000–99999，如微信 xweb_sandboxed / 浏览器的
    # sandboxed_process）本来就没有 /storage，不是 SI 的隔离对象：直接跳过，不计
    # checked/broken、不发 G、不写 seen/退避，避免把“没有沙箱”误判成“沙箱丢失”。
    # 普通应用 uid 10000–19999 不受影响。
    if (uid + 0 >= isomin && uid + 0 <= isomax) next
    if (int(uid / 100000) != 0) next
    if (pkg !~ ("^(" pkgs ")(:|$)")) next
    # 子进程 argv[0] 可能是 pkg:push（进程名带冒号）；配置/身份/seen 都按基础包名查。
    base = pkg; sub(/:.*/, "", base); pkg = base

    mi = proc "/" pid "/mountinfo"
    r = (getline first < mi)
    if (r < 0) { close(mi); next }
    # 只有配置里真实启用的包才算“已隔离进程”，checked 不在 EN 过滤前加。
    if (!(pkg in EN)) { close(mi); next }
    checked++
    age = secs(et)
    if (age < amin) { young++; close(mi); next }
    val = EN[pkg]; i = index(val, ":")
    en = substr(val, 1, i - 1); allow = substr(val, i + 1)
    if (en != "1") { print "S|" pkg "|disabled"; close(mi); next }
    if (verbose && allow != "") print "A|" pkg "|" allow
    if (r == 0) { close(mi); next }

    SB = ""; SDEV = ""; MP = ""; SFT = ""
    APP_S = ""; APP_M = ""; APP_SFT = ""; APP_MFT = ""
    TROOT = ""; TN = 0
    split("", TD); split("", TC)
    parse_mi(first)
    while ((getline ml < mi) > 0) parse_mi(ml)
    close(mi)
    # PID/ns TOCTOU：扫描时把进程的 starttime 与真实 uid 一起记下来，
    # shell 侧在真正 bind/umount 前再读一次比对（进程重启/换 ns 就不动手）。
    pst = ""; puid = ""
    pstf = proc "/" pid "/stat"
    if ((getline pstl < pstf) > 0) {
      sub(/^.*\) /, "", pstl)
      if (split(pstl, psta, " ") >= 20) pst = psta[20]
    }
    close(pstf)
    pstf = proc "/" pid "/status"
    while ((getline pstl < pstf) > 0) {
      if (pstl ~ /^Uid:/) { split(pstl, psta, /[ \t]+/); puid = psta[2]; break }
    }
    close(pstf)
    if (SB == "") {
      # 应用 /storage（或 /mnt）还是旧 FUSE（分叉）：跨 ns 修不了，只报僵死。
      if (APP_S != "" && APP_S != HOSTM && APP_SFT == "fuse") print "ST|" pid "|" uid "|" age "|" pkg "|" APP_S
      else if (APP_S == "" && APP_M != "" && APP_M != HOSTM && APP_MFT == "fuse") print "ST|" pid "|" uid "|" age "|" pkg "|" APP_M
      # 末列 has-storage：应用 ns 里连存储根（/storage/emulated 或 /mnt/user/0/emulated）
      # 都没有时，这个进程不是 SI 的隔离对象（isolated 子进程就是这种形态），
      # 重建沙箱会写无效退避；shell 侧据此报 na 而不是 gone。
      else print "G|" pid "|" uid "|" age "|" pkg "|" pst "|" puid "|" ((APP_S != "" || APP_M != "") ? 1 : 0)
      next
    }

    # 身份/层保护：沙箱根必须属于该包（shared- 前缀忽略），且必须已在 FUSE 层，否则不动。
    rid = SB
    sub(/^.*\/Android\/data\//, "", rid)
    sub(/\/.*/, "", rid)
    pkgid = pkg; sub(/^shared-/, "", pkgid)
    rid2 = rid; sub(/^shared-/, "", rid2)
    if (rid2 == "" || rid2 != pkgid) {
      print "S|" pkg "|identity|" rid2
      next
    }
    if (!(SDEV == HOSTM && (APP_S == "" || APP_S == HOSTM))) {
      # 旧 FUSE 会话已从宿主消失、沙箱本身又是 fuse：僵死挂载，跨 namespace 无法修。
      # 其它情况（宿主里仍有该设备，或根本不是 FUSE）保持原来的 layer 语义。
      if (SFT == "fuse" && !(SDEV in HOSTDEV)) print "ST|" pid "|" uid "|" age "|" pkg "|" SDEV
      else print "S|" pkg "|layer|" SDEV "|" HOSTM
      next
    }
    if (SB ~ /^\/media\//) sbpath = dataroot "/media" substr(SB, 7)
    else if (SB ~ /^\/[0-9]+\/Android\/data\//) sbpath = dataroot "/media" SB
    else next

    # 主扫描也校验 target 的栈顶与层数：只有“栈顶==SB 且只有一层”才算健康。
    # 残留旧根/别的沙箱叠在上面时保留现状（stale/rollback），不登记 K、不动子目录。
    if (TN != 1 || TROOT != SB) {
      print "RS|" pid "|" uid "|" age "|" pkg "|" TN "|" TROOT "|" SB
      next
    }

    # 合法沙箱（身份/层都通过、路径形态可解释）→ 供 shell 登记身份证据。
    # pst/puid 是扫描时刻的进程指纹；sbpath 放最后，路径里出现 | 时也不会错位。
    # K 行带 uid/starttime：seen 证据按 pkg+boot+ns+uid+starttime 匹配，ns inode 被
    # 复用给别的进程时不会假命中。
    print "K|" pid "|" pkg "|" SB "|" pst "|" puid
    print "I|" pid "|" age "|" pkg "|" MP "|" pst "|" puid "|" sbpath

    m = split(allow, dirs, " ")
    for (j = 1; j <= m; j++) {
      n = dirs[j]; t = MP "/" n
      act = target_action(t)
      k = pkg SUBSEP n
      if ((act == "b" || act == "r") && dry == 0) {
        ca = churn_decide(k)
        if (ca == "churn-new") { print "N|" pkg "|" n "|wait|" (now + 600); act = "churn" }
        else if (ca == "churn") act = "churn"
        else if (ca == "retry") act = "retry"
      }
      note_target(k, pkg, n, act)
      print "T|" pid "|a|" n "|" act
    }

    for (j = 1; j <= 3; j++) {
      n = (j == 1 ? "data" : (j == 2 ? "media" : "obb"))
      tname = "Android/" n "/" pkg
      t = MP "/" tname
      act = target_action(t)
      k = pkg SUBSEP tname
      if ((act == "b" || act == "r") && dry == 0) {
        ca = churn_decide(k)
        if (ca == "churn-new") { print "N|" pkg "|" tname "|wait|" (now + 600); act = "churn" }
        else if (ca == "churn") act = "churn"
        else if (ca == "retry") act = "retry"
      }
      note_target(k, pkg, tname, act)
      print "T|" pid "|t|" tname "|" act
    }
  }
  END {
    if (FUSE_BAD) exit 9
    if (BAD_CFG) exit 5
    if (NR < 2) exit 4
    if (dry == 0) for (k in CAND) if (!(k in BADK)) print "C|" CPKG[k] "|" CTGT[k]
    print "Z|" checked "|" young "|" CHURN "|" RETRY_IN
  }' > "$OUTF" 2>/dev/null
arc=$?
if [ "$arc" -eq 9 ]; then
  say "FUSE 层尚未就绪，本轮不修改挂载（交给守护退避重试）"
  result_line 0 0 0 0 defer=fuse
  exit 0
fi
if [ "$arc" -eq 5 ]; then
  # 缓存坏了（@PKGS 为空等）：删掉，下一轮从配置重建。
  [ "$DRY" = 0 ] && rm -f "$CACHE" 2>/dev/null
  say "配置缓存无效，跳过本轮"
  result_line 0 0 0 0 error=config
  exit 2
fi
if [ "$arc" -eq 4 ]; then
  say "ps 不可用或输出异常，跳过本轮"
  result_line 0 0 0 0 error=ps
  exit 4
fi
if [ "$arc" -ne 0 ]; then
  say "扫描异常（rc=$arc），跳过本轮"
  result_line 0 0 0 0 error=scan
  exit 4
fi

checked=0; broken=0; fixed=0; young=0; churn=0; retry_in=0
FUSEDEV=""
SAND_REBUILT=0
BOFF_IN=0
pid=""; age=""; pkg=""; mp=""; sbpath=""
# 每个进程的扫描时刻指纹（starttime/uid/ns）；动手前用 pid_check 再读比对。
pid_start=""; pid_uid=""; pid_ns=""; kp_pid=""; kp_ns=""
need=""; need_meta=""; proc_broken=0
skipped="$EXTRA_SKIP"

rep_add_pkg() {   # $1=pkg $2=target $3=fixed|failed $4=ns（可空）
  # 记录 bind 的实际时刻（秒.毫秒）：熔断的 <1 秒判据依赖它。
  # 第 5 列 ctx=dev@boot@ns 只给失败退避用；第 6 列 mono 是退避用的单调秒数。
  # 旧版本的行没有 mono 列（只有墙钟），退避按“无退避”处理。
  set_now
  _ms=""
  if [ "$SI_TEST" = 1 ] && [ -n "$SI_TEST_NOW" ]; then
    _ms="${NOW}000"
  else
    _ms=$(date +%s%3N 2>/dev/null)
  fi
  case "$_ms" in ''|*[!0-9]*) _ms="${NOW}000" ;; esac
  _sec=${_ms%???}; _frac=${_ms#"$_sec"}
  [ "${#_frac}" = 3 ] || _frac=000
  n=0
  [ -f "$REP" ] && n=$(wc -l < "$REP" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -ge 200 ]; then
    tail -n 199 "$REP" > "$REP.tmp.$$" 2>/dev/null && mv -f "$REP.tmp.$$" "$REP" 2>/dev/null
  fi
  set_mono
  _ctx=""
  [ -n "${4:-}" ] && _ctx=" ctx=$FUSEDEV@$BOOT_ID@$4"
  echo "$_sec.$_frac $1 $2 $3$_ctx mono=$MONO" >> "$REP" 2>/dev/null
}
rep_add() {   # $1=target $2=fixed|failed $3=ns（可空）
  rep_add_pkg "$pkg" "$1" "$2" "${3:-}"
}

# 失败退避：同一 (包, target, FUSE dev, boot, namespace) 的 failed 行未过期时不再试。
# dev/boot/ns 任一变化都会落到不同的 key（旧行自然失效）。
# 过期判断只看 mono（/proc/uptime）：系统时间被改不会让退避提前到期或无限延长。
backoff_left() {   # pkg target ns -> 剩余秒数（0=不在退避期）
  set_mono
  [ "$MONO" -gt 0 ] 2>/dev/null || { printf '0\n'; return 0; }
  [ -s "$REP" ] || { printf '0\n'; return 0; }
  _bl=$(awk -v p="$1" -v t="$2" -v ctx="ctx=$FUSEDEV@$BOOT_ID@$3" \
             -v mono="$MONO" -v win="$SB_BACKOFF" '
    $2 == p && $3 == t && $4 == "failed" && $5 == ctx {
      ts = $6
      sub(/^mono=/, "", ts)
      # 旧格式行没有 mono（墙钟时间戳）：不参与退避。
      if (ts !~ /^[0-9]+$/) next
      if (ts + 0 > last) last = ts + 0
    }
    END {
      left = last + win - mono
      if (last == 0 || left <= 0) print 0
      else printf "%d\n", left
    }' "$REP" 2>/dev/null)
  case "$_bl" in ''|*[!0-9]*) _bl=0 ;; esac
  printf '%s\n' "$_bl"
}
backoff_note() {   # 收拢本轮最短的退避剩余，放进 RESULT retry=
  [ "$1" -gt 0 ] 2>/dev/null || return 0
  if [ "$BOFF_IN" -eq 0 ] || [ "$1" -lt "$BOFF_IN" ]; then BOFF_IN=$1; fi
}

churn_del() {   # pkg target
  [ -s "$CH" ] || return 0
  awk -F'|' -v p="$1" -v t="$2" '!($1 == p && $2 == t)' "$CH" > "$CH.tmp.$$" 2>/dev/null \
    && mv -f "$CH.tmp.$$" "$CH" 2>/dev/null
}
churn_put() {   # pkg target state until
  churn_del "$1" "$2"
  printf '%s|%s|%s|%s\n' "$1" "$2" "$4" "$3" >> "$CH" 2>/dev/null
}

repair_one() {   # $1=target $2=action
  rt=$1; ra=$2
  tgt=$mp/$rt
  src=$SRC_ROOT/0/$rt
  mi=$PROC/$pid/mountinfo
  pns=$(ns_of "$pid")
  boff=$(backoff_left "$pkg" "$rt" "$pns")
  if [ "$boff" -gt 0 ]; then
    backoff_note "$boff"
    return 0
  fi

  if [ ! -d "$src" ]; then
    skipped="$skipped source"
    say "  跳过 $rt（源不存在）"
    rep_add "$rt" failed "$pns"
    [ "$ra" = "retry" ] && { churn_put "$pkg" "$rt" block "$((NOW + 3600))"; churn=$((churn + 1)); skipped="$skipped churn"; echo "N|$pkg|$rt|block|$((NOW + 3600))"; }
    return 0
  fi
  if ! timeout 2 nsenter -t "$pid" -m -- test -d "$src" </dev/null 2>/dev/null; then
    skipped="$skipped source_ns"
    say "  跳过 $rt（应用 namespace 里看不到源）"
    rep_add "$rt" failed "$pns"
    [ "$ra" = "retry" ] && { churn_put "$pkg" "$rt" block "$((NOW + 3600))"; churn=$((churn + 1)); skipped="$skipped churn"; echo "N|$pkg|$rt|block|$((NOW + 3600))"; }
    return 0
  fi

  set -- $(stat_of "$tgt"); c=${1:-}; k=${2:-0}
  # 扫描到动手之间进程可能已重启：starttime/uid/ns 任一变化就不碰挂载。
  if ! pid_check "$pid"; then
    skipped="$skipped pid_changed"
    say "  跳过 $rt（进程已变化：pid/uid/ns 与扫描时不一致）"
    return 0
  fi
  # 扫描到动手之间 SI 可能已自愈：已是“同层一条”就别拆了重挂。
  if [ "$c" = "$FUSEDEV" ] && [ "$k" = "1" ]; then
    [ "$ra" = "retry" ] && churn_del "$pkg" "$rt"
    return 0
  fi
  j=0
  while [ "$j" -lt 4 ] && [ "$k" -gt 0 ]; do
    umount_one "$pid" "$tgt" >/dev/null 2>&1
    j=$((j + 1))
    set -- $(stat_of "$tgt"); k=${2:-0}
  done
  if [ "$k" -gt 0 ]; then
    say "  跳过 $rt（umount 未生效）"
    rep_add "$rt" failed "$pns"
    [ "$ra" = "retry" ] && { churn_put "$pkg" "$rt" block "$((NOW + 3600))"; churn=$((churn + 1)); skipped="$skipped churn"; echo "N|$pkg|$rt|block|$((NOW + 3600))"; }
    return 0
  fi

  # bind 命令的 stderr 不一定代表失败（挂载成功也可能有警告）；以挂载校验为准，
  # 否则会出现“实际挂上了却记 bindfail，下一轮又判健康”的假失败。
  err=$(bind_mount "$pid" "$src" "$tgt" 2>&1)
  set -- $(stat_of "$tgt")
  c=${1:-}; k=${2:-0}
  if [ "$c" = "$FUSEDEV" ] && [ "$k" = "1" ]; then
    [ -n "$err" ] && say "  警告 $rt: 命令有输出但挂载校验通过（$err）"
    # 同包多 PID 共用 (pkg,ns,target)：同 ns 的成功只计一次；
    # 不同 namespace（主进程/子进程）是两次分开的挂载，键必须带 ns。
    if ! grep -qxF "$pkg|$pns|$rt" "$FIXED_LIST" 2>/dev/null; then
      fixed=$((fixed + 1))
      rep_add "$rt" fixed "$pns"
      printf '%s|%s|%s\n' "$pkg" "$pns" "$rt" >> "$FIXED_LIST" 2>/dev/null
    fi
    [ "$ra" = "retry" ] && churn_del "$pkg" "$rt"
  else
    if [ -n "$err" ]; then
      say "  失败 $rt: $err"
      skipped="$skipped bindfail"
    else
      say "  校验失败 $rt (dev=$c n=$k)，回滚"
    fi
    umount_one "$pid" "$tgt" >/dev/null 2>&1
    rep_add "$rt" failed "$pns"
    [ "$ra" = "retry" ] && { churn_put "$pkg" "$rt" block "$((NOW + 3600))"; churn=$((churn + 1)); skipped="$skipped churn"; echo "N|$pkg|$rt|block|$((NOW + 3600))"; }
  fi
}

seen_sb_any() {  # pkg -> 本 boot 任意 ns 记录的 SB
  _sba_pkg=$1
  for _se in $SEEN_LIST; do
    _eifs=$IFS; IFS='|'; set -- $_se; IFS=$_eifs
    if [ "${1:-}" = "$_sba_pkg" ] && [ "${2:-}" = "$BOOT_ID" ] && [ -n "${6:-}" ]; then
      printf '%s\n' "${6}"
      return 0
    fi
  done
  return 1
}
sandbox_probe() {  # pid uid path mode；设置 SP_EXISTS/SP_OWNER_BAD
  _sbp_pid=$1; _sbp_uid=$2; _sbp_path=$3; _sbp_mode=$4
  if [ -L "$_sbp_path" ] || [ ! -d "$_sbp_path" ]; then return 1; fi
  SP_EXISTS=1
  if [ "$_sbp_mode" = 1 ]; then
    if ! timeout 2 nsenter -t "$_sbp_pid" -m -- test -d "$_sbp_path" </dev/null 2>/dev/null; then
      return 1
    fi
    _sbp_owner=$(sandbox_owner_ns "$_sbp_pid" "$_sbp_path")
  else
    _sbp_owner=$(sandbox_owner "$_sbp_path")
  fi
  if [ "$_sbp_owner" != "$_sbp_uid" ]; then SP_OWNER_BAD=1; return 1; fi
  return 0
}
sandbox_unmount() {  # pid tgt -> 0 已卸干净
  _su_pid=$1; _su_tgt=$2; _su_i=0
  _su_mi=$mi
  mi=$PROC/$_su_pid/mountinfo
  set -- $(stat_src_of "$_su_tgt"); _su_n=${2:-0}
  while [ "$_su_n" -gt 0 ] && [ "$_su_i" -lt 4 ]; do
    umount_one "$_su_pid" "$_su_tgt" >/dev/null 2>&1
    _su_i=$((_su_i + 1))
    set -- $(stat_src_of "$_su_tgt"); _su_n=${2:-0}
  done
  mi=$_su_mi
  [ "$_su_n" -eq 0 ]
}
sandbox_restore_root() {  # 按原 root 把被临时卸下的普通 FUSE 根挂回去并校验
  [ "${rb_root_removed:-0}" = 1 ] || return 0
  _rr_mi=$mi
  mi=$PROC/$rb_pid/mountinfo
  case "${rb_root_src:-}" in
    /)  _rr_src=/storage/emulated ;;
    /0)
      # root=/0 优先从 FUSE 层的 /0 挂回（root 才能保持 /0）；
      # 应用 ns 看不到它时退回 self-bind target，root 同样落到 /0。
      if timeout 2 nsenter -t "$rb_pid" -m -- test -d "$SRC_ROOT/0" </dev/null 2>/dev/null; then
        _rr_src=$SRC_ROOT/0
      else
        _rr_src=$rb_tgt
      fi
      ;;
    *)
      # 其它 root 拆之前就不会卸；走到这里说明状态异常，fail-closed 不猜着挂。
      mi=$_rr_mi
      skipped="$skipped rollback"
      say "  原 FUSE 根的 root=${rb_root_src:-?} 无法按原样恢复，保留现状"
      rb_root_removed=0
      return 1
      ;;
  esac
  bind_mount "$rb_pid" "$_rr_src" "$rb_tgt" >/dev/null 2>&1
  set -- $(stat_src_of "$rb_tgt"); _rr_dev=${1:-}; _rr_n=${2:-0}; _rr_s=${3:-}
  mi=$_rr_mi
  rb_root_removed=0
  # 必须“一层、设备号等于原设备、root 等于原 root”才算挂回，否则不谎报。
  if [ "$_rr_n" = 1 ] && [ "$_rr_dev" = "${rb_root_dev:-$FUSEDEV}" ] \
     && [ "$_rr_s" = "${rb_root_src:-}" ]; then
    say "  已把原 FUSE 根挂回 $rb_tgt（root=$rb_root_src）"
    return 0
  fi
  skipped="$skipped rollback"
  say "  原 FUSE 根恢复失败（dev=${_rr_dev:-?} n=$_rr_n root=${_rr_s:-?}，应为 dev=${rb_root_dev:-?} root=${rb_root_src:-?}），保留现状"
  return 1
}
sandbox_rollback() {  # pid tgt：0=完整回滚 1=沙箱没卸干净 2=沙箱卸了但原根没恢复
  if sandbox_unmount "$1" "$2"; then
    if sandbox_restore_root; then
      return 0
    fi
    return 2
  fi
  skipped="$skipped rollback"
  return 1
}

# 选一个可用的沙箱源：优先本 boot 该包（同 ns 优先）的 SB，再 pkg/shared-pkg 的
# sdcard/cache 变体；没有 SB 且多个变体都可用时 fail-closed，拒绝猜。
# mode=0 只查宿主存在/属主（dry-run 资格）；mode=1 还要求应用 ns 可见+属主。
# 成功输出 "<sandbox-id>|<path>"；失败输出原因（missing/owner/hidden/ambiguous）。
sandbox_pick() {   # pid uid pkg ns mode
  sp_pid=$1; sp_uid=$2; sp_pkg=$3; sp_ns=$4; sp_mode=$5
  SP_EXISTS=0; SP_OWNER_BAD=0
  sp_seen_paths=""
  sp_sb=$(seen_sb "$sp_pkg" "$sp_ns" 2>/dev/null)
  [ -n "$sp_sb" ] || sp_sb=$(seen_sb_any "$sp_pkg" 2>/dev/null)
  if [ -n "$sp_sb" ]; then
    sp_src=$(sb_to_src "$sp_sb")
    sp_seen_paths="$sp_seen_paths $sp_src"
    if sandbox_probe "$sp_pid" "$sp_uid" "$sp_src" "$sp_mode"; then
      sp_id2=${sp_src#*/Android/data/}
      sp_id2=${sp_id2%%/*}
      printf '%s|%s\n' "$sp_id2" "$sp_src"
      return 0
    fi
    # SB 记录的路径存在但不可用（属主/可见性）：不猜别的变体。
    if [ "$SP_EXISTS" = 1 ]; then
      if [ "$SP_OWNER_BAD" = 1 ]; then printf 'owner\n'
      else printf 'hidden\n'
      fi
      return 1
    fi
    # SB 路径不存在：继续按 pkg/shared/cache 变体找。
  fi
  sp_vars=""
  for sp_id in "$sp_pkg" "shared-$sp_pkg"; do
    for sp_sub in "sdcard" "cache/sdcard"; do
      sp_vars="$sp_vars
$sp_id $SRC_ROOT/0/Android/data/$sp_id/$sp_sub"
    done
  done
  sp_hits=0; sp_hit=""
  while read -r sp_id sp_src; do
    [ -n "$sp_id" ] || continue
    case " $sp_seen_paths " in *" $sp_src "*) continue ;; esac
    sp_seen_paths="$sp_seen_paths $sp_src"
    sandbox_probe "$sp_pid" "$sp_uid" "$sp_src" "$sp_mode" || continue
    sp_hits=$((sp_hits + 1))
    sp_hit="$sp_id|$sp_src"
  done <<EOF
$sp_vars
EOF
  if [ "$sp_hits" -gt 1 ]; then printf 'ambiguous\n'; return 2; fi
  if [ "$sp_hits" -eq 1 ]; then printf '%s\n' "$sp_hit"; return 0; fi
  if [ "$SP_EXISTS" = 0 ]; then printf 'missing\n'
  elif [ "$SP_OWNER_BAD" = 1 ]; then printf 'owner\n'
  else printf 'hidden\n'
  fi
  return 1
}

# 没有本 boot 同 ns 同进程（uid/starttime 也一致）的 seen 时，普通 FUSE 根不拆不 bind（R4 的安全门）。
sandbox_stack_blocked() {   # pid pkg ns -> 0=目标栈顶是普通 FUSE 根且无同 ns 证据
  _ssb_pid=$1; _ssb_pkg=$2; _ssb_ns=$3
  _ssb_uid=$(pid_real_uid "$_ssb_pid")
  _ssb_start=$(pid_starttime "$_ssb_pid")
  seen_match "$_ssb_pkg" "$_ssb_ns" "$_ssb_uid" "$_ssb_start" && return 1
  _ssb_mi=$mi
  mi=$PROC/$_ssb_pid/mountinfo
  set -- $(stat_src_of /storage/emulated/0)
  _ssb_dev=${1:-}; _ssb_n=${2:-0}; _ssb_s=${3:-}
  mi=$_ssb_mi
  [ "$_ssb_n" -gt 0 ] && [ "$_ssb_dev" = "$FUSEDEV" ] \
    && { [ "$_ssb_s" = "/" ] || [ "$_ssb_s" = "/0" ]; }
}

# Android isolated 子进程的 uid 区间：这类进程不是 SI 的隔离对象（没有 /storage），
# 不应触发沙箱重建、更不该写 180 秒失败退避。
sand_isolated_uid() {   # uid -> 0 表示 isolated
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge "$ISO_UID_MIN" ] && [ "$1" -le "$ISO_UID_MAX" ]
}
sand_report_gone() {   # pkg reason：gone 行带 pid/uid/ns/reason，daemon 写进日志并按事件去重
  sand_report gone "$1" "pid=$rb_pid uid=$rb_uid ns=$rb_ns reason=$2 isolated=${rb_iso:-0}"
}

# 沙箱丢失重建：只在“曾经见过沙箱，或沙箱目录存在且属主匹配”的进程 ns 里补沙箱根。
# 返回 0=已重建 1=失败（报 sandbox_gone） 2=无需动作/从未隔离（静默）
#      3=安全策略拒绝（报 sandbox_skip，不动挂载）
#      5=不是隔离对象（isolated / 应用 ns 没有 /storage，报 na，不写退避、不计 broken）。
rebuild_sandbox() {   # pid uid pkg ns [has_storage]
  rb_pid=$1; rb_uid=$2; rb_pkg=$3; rb_ns=$4; rb_hasst=${5:-1}
  rb_tgt=/storage/emulated/0
  rb_mi=$PROC/$rb_pid/mountinfo
  rb_iso=0
  sand_isolated_uid "$rb_uid" && rb_iso=1

  # -1) isolated 子进程（微信 xweb_sandboxed 等）本来就不是 SI 隔离对象。正常扫描已在
  #     awk 里按 uid 过滤、走不到这里；这条分支只作防御（直接调用/未来扫描改动），
  #     只报 na，不探测、不写 .repairs 退避、不计 broken。
  if [ "$rb_iso" = 1 ]; then
    say "  跳过沙箱 $rb_pkg（isolated/无 storage，跳过：pid=$rb_pid uid=$rb_uid reason=isolated）"
    sand_report na "$rb_pkg" "pid=$rb_pid uid=$rb_uid ns=$rb_ns reason=isolated isolated=1"
    return 5
  fi

  # 0) 失败退避：dev/boot/ns 不变时，同一坏包不再每轮 bind/回滚。
  #    退避期内仍上报同一事件（reason=backoff），但 daemon 按 pkg/pid/uid/ns 去重，
  #    不会每轮刷日志；保留这条报告是为了让 daemon 判断事件是否仍然存在——一旦
  #    应用自愈（本轮报告里不再有该事件），旧签名会被清掉，下次真丢会重新记一条。
  rb_left=$(backoff_left "$rb_pkg" "$SAND_KEY" "$rb_ns")
  if [ "$rb_left" -gt 0 ]; then
    backoff_note "$rb_left"
    sand_report_gone "$rb_pkg" backoff
    return 1
  fi

  # 1) 资格：本 boot seen 身份，或没有旧 boot 证据时“源存在且属主==uid”。
  if ! sandbox_eligible "$rb_pid" "$rb_uid" "$rb_pkg" "$rb_ns"; then
    return 2
  fi

  # 1b) 有重建资格、但应用 ns 里连存储根都没有，且该包在本 boot 没有任何 seen 证据：
  #     从未隔离过（也不是 isolated uid）的进程不是 SI 隔离对象，报 na 跳过，
  #     不写退避、不计 broken。有 seen 证据的普通应用即使 has-storage=0 也按真实
  #     丢失处理：继续走下面的拆普通根/重建与失败退避，不能被误判成“无需重建”。
  if [ "$rb_hasst" = 0 ] && ! seen_cur_boot_any "$rb_pkg"; then
    say "  跳过沙箱 $rb_pkg（isolated/无 storage，跳过：pid=$rb_pid uid=$rb_uid reason=no-storage）"
    sand_report na "$rb_pkg" "pid=$rb_pid uid=$rb_uid ns=$rb_ns reason=no-storage isolated=0"
    return 5
  fi

  # 2) 普通 FUSE 根只有在应用重启、本 boot 同 ns 的 seen 仍有效时才允许拆；
  #    缺少证据时 fail-closed，避免把真实存储根换成一个猜出来的沙箱。
  if sandbox_stack_blocked "$rb_pid" "$rb_pkg" "$rb_ns"; then
    sand_report skip "$rb_pkg"
    return 3
  fi

  rb_pick=$(sandbox_pick "$rb_pid" "$rb_uid" "$rb_pkg" "$rb_ns" 1)
  rb_rc=$?
  if [ "$rb_rc" -ne 0 ]; then
    rb_reason=$rb_pick
    case "$rb_reason" in
      missing) say "  跳过沙箱 $rb_pkg（源不存在或不是目录）" ;;
      owner)   say "  跳过沙箱 $rb_pkg（属主与进程 uid $rb_uid 不符）" ;;
      hidden)  say "  跳过沙箱 $rb_pkg（应用 namespace 看不到源）" ;;
      ambiguous) say "  跳过沙箱 $rb_pkg（多个源变体且无 SB，拒绝猜测）" ;;
      *)       say "  跳过沙箱 $rb_pkg（源不可用）" ;;
    esac
    rep_add_pkg "$rb_pkg" "$SAND_KEY" failed "$rb_ns"
    sand_report_gone "$rb_pkg" "$rb_reason"
    return 1
  fi
  _rb_ifs=$IFS; IFS='|'; set -- $rb_pick; IFS=$_rb_ifs
  rb_id=${1:-}; rb_src=${2:-}

  # 扫描到动手之间进程可能已重启：starttime/uid/ns 任一变化就不碰挂载。
  if ! pid_check "$rb_pid"; then
    skipped="$skipped pid_changed"
    say "  跳过沙箱 $rb_pkg（进程已变化：pid/uid/ns 与扫描时不一致）"
    return 2
  fi

  # 3) 目标必须存在，且当前不是沙箱；普通 FUSE 根可先卸掉再 bind。
  if ! timeout 2 nsenter -t "$rb_pid" -m -- test -d "$rb_tgt" </dev/null 2>/dev/null; then
    say "  跳过沙箱 $rb_pkg（目标不存在）"
    rep_add_pkg "$rb_pkg" "$SAND_KEY" failed "$rb_ns"
    sand_report_gone "$rb_pkg" no-target
    return 1
  fi
  mi=$rb_mi
  rb_root_removed=0; rb_root_src=""; rb_root_dev=""
  set -- $(stat_src_of "$rb_tgt"); rb_dev=${1:-}; rb_n=${2:-0}; rb_s=${3:-}
  if [ "$rb_n" -gt 0 ]; then
    if sandbox_src_match "$rb_s" "$rb_id" \
       || sandbox_src_match "$rb_s" "$rb_pkg" \
       || sandbox_src_match "$rb_s" "shared-$rb_pkg"; then
      say "  跳过沙箱 $rb_pkg（目标已是沙箱，无需重建）"
      return 2
    fi
    if [ "$rb_n" = 1 ] && [ "$rb_dev" = "$FUSEDEV" ] \
       && { [ "$rb_s" = "/" ] || [ "$rb_s" = "/0" ]; }; then
      # 拆根前再查一次：资格检查到这里的窗口里，SI 可能刚把普通根挂回来。
      if sandbox_stack_blocked "$rb_pid" "$rb_pkg" "$rb_ns"; then
        sand_report skip "$rb_pkg"
        return 3
      fi
      # 恢复要按原 root 来：先钉住 (dev, root)，确认真的卸空了才记“已卸下”。
      rb_root_src=$rb_s
      rb_root_dev=$rb_dev
      umount_one "$rb_pid" "$rb_tgt" >/dev/null 2>&1
      set -- $(stat_src_of "$rb_tgt"); rb_dev=${1:-}; rb_n=${2:-0}; rb_s=${3:-}
      if [ "$rb_n" -ne 0 ]; then
        rb_root_src=""; rb_root_dev=""
        say "  跳过沙箱 $rb_pkg（umount 未生效 dev=${rb_dev:-?} n=$rb_n src=${rb_s:-?}），保留现状"
        rep_add_pkg "$rb_pkg" "$SAND_KEY" failed "$rb_ns"
        sand_report_gone "$rb_pkg" umount
        return 1
      fi
      # 只有确认真的卸空了才记“原根已卸”；否则后续 restore/rollback 都失去依据。
      rb_root_removed=1
      say "  目标 /storage/emulated/0 是普通 FUSE 根（root=$rb_root_src），已卸下后重挂沙箱"
    else
      # 目标被别的层/残留沙箱占用：不是“沙箱丢失可重试”，只能等应用重启让 SI
      # 重建 namespace；不写 failed 行，避免每 180 秒无效重试和“会尝试重建”文案。
      say "  跳过沙箱 $rb_pkg（目标被其他挂载占用 dev=${rb_dev:-?} src=${rb_s:-?}，需要重启应用）"
      sand_report skip "$rb_pkg"
      return 3
    fi
  fi

  err=$(bind_mount "$rb_pid" "$rb_src" "$rb_tgt" 2>&1)
  set -- $(stat_src_of "$rb_tgt"); rb_dev=${1:-}; rb_n=${2:-0}; rb_s=${3:-}
  if [ "$rb_n" -gt 1 ]; then
    # 与主扫描一致：只有一层本包沙箱才算健康。叠层可能是 SI 并发挂载，
    # 不盲目 umount，也不计 fixed；保留现状交给应用重启收敛。
    [ -n "$err" ] && say "  沙箱 bind 输出: $err"
    say "  跳过沙箱 $rb_pkg（并发挂载 dev=${rb_dev:-?} n=$rb_n src=${rb_s:-?}，保留现状）"
    skipped="$skipped rollback"
    sand_report stale "$rb_pkg"
    return 4
  fi
  rb_ok=0
  sandbox_src_match "$rb_s" "$rb_id" || rb_ok=1
  [ "$rb_dev" = "$FUSEDEV" ] || rb_ok=1
  [ "$rb_n" = "1" ] || rb_ok=1
  if [ "$rb_ok" -ne 0 ]; then
    [ -n "$err" ] && say "  沙箱 bind 输出: $err"
    rb_report=gone
    sandbox_rollback "$rb_pid" "$rb_tgt"
    case $? in
      0) say "  跳过沙箱 $rb_pkg（bind 后校验失败 dev=${rb_dev:-?} n=$rb_n src=${rb_s:-?}，已回滚）" ;;
      2) rb_report=stale ;;
      *) say "  跳过沙箱 $rb_pkg（校验失败且回滚未卸干净，保留现状）" ; rb_report=stale ;;
    esac
    if [ "$rb_report" = stale ]; then
      sand_report stale "$rb_pkg"
      return 4
    fi
    rep_add_pkg "$rb_pkg" "$SAND_KEY" failed "$rb_ns"
    sand_report_gone "$rb_pkg" bindfail
    return 1
  fi
  [ -n "$err" ] && say "  警告 沙箱 $rb_pkg: 命令有输出但挂载校验通过（$err）"
  # bind 后必须在应用 ns 里确认 target 可读，防“挂上了但一读就 EIO”。
  if ! timeout 2 nsenter -t "$rb_pid" -m -- test -r "$rb_tgt" </dev/null 2>/dev/null; then
    rb_report=gone
    sandbox_rollback "$rb_pid" "$rb_tgt"
    case $? in
      0) say "  跳过沙箱 $rb_pkg（bind 后在应用内不可读，已回滚）" ;;
      2) rb_report=stale ;;
      *) say "  跳过沙箱 $rb_pkg（应用内不可读且回滚未卸干净，保留现状）" ; rb_report=stale ;;
    esac
    if [ "$rb_report" = stale ]; then
      sand_report stale "$rb_pkg"
      return 4
    fi
    rep_add_pkg "$rb_pkg" "$SAND_KEY" failed "$rb_ns"
    sand_report_gone "$rb_pkg" unreadable
    return 1
  fi

  # 4) 复用 repair_one 补 allow 目录与 Android/{data,media,obb}/<pkg>；
  #    共享目录源不可见时不能留下“空沙箱”，回滚刚 bind 的沙箱。
  pid=$rb_pid; pkg=$rb_pkg; mp=$rb_tgt; sbpath=$rb_src; mi=$rb_mi
  rb_fixed0=$fixed
  rb_repbak=""; rb_listbak=""
  [ -f "$REP" ] && { rb_repbak="$REP.bak.$$"; cp -f "$REP" "$rb_repbak" 2>/dev/null; }
  [ -f "$FIXED_LIST" ] && { rb_listbak="$FIXED_LIST.bak.$$"; cp -f "$FIXED_LIST" "$rb_listbak" 2>/dev/null; }
  rb_skip0=$skipped
  rb_allow=$(allow_of "$rb_id")
  [ -n "$rb_allow" ] || rb_allow=$(allow_of "$rb_pkg")
  [ -n "$rb_allow" ] || rb_allow=$(allow_of "shared-$rb_pkg")
  if [ -n "$rb_allow" ]; then
    # 目录名里的 * ? [ 是字面量（配置允许），关掉 glob 再按空格遍历。
    set -f
    for rb_d in $rb_allow; do
      [ -n "$rb_d" ] || continue
      if [ ! -d "$sbpath/$rb_d" ]; then
        skipped="$skipped target_missing"
        say "  跳过 $rb_d（锚点目录缺失：$sbpath/$rb_d）"
        continue
      fi
      rb_act=$(target_action_shell "$mp/$rb_d")
      case "$rb_act" in
        0) continue ;;
        s) skipped="$skipped layer"; say "  跳过 $rb_d（挂载在其他层，不动）"; continue ;;
        *) repair_one "$rb_d" b ;;
      esac
    done
    set +f
  fi
  for rb_d in "Android/data/$rb_pkg" "Android/media/$rb_pkg" "Android/obb/$rb_pkg"; do
    if [ ! -d "$sbpath/${rb_d%/*}" ]; then
      skipped="$skipped target_missing"
      say "  跳过 $rb_d（锚点目录缺失：$sbpath/${rb_d%/*}）"
      continue
    fi
    if [ ! -d "$DATA_ROOT/media/0/$rb_d" ]; then
      skipped="$skipped target_missing"
      say "  跳过 $rb_d（目标目录缺失：$DATA_ROOT/media/0/$rb_d）"
      continue
    fi
    rb_act=$(target_action_shell "$mp/$rb_d")
    case "$rb_act" in
      0) continue ;;
      s) skipped="$skipped layer"; say "  跳过 $rb_d（挂载在其他层，不动）"; continue ;;
      *) repair_one "$rb_d" b ;;
    esac
  done
  rb_added=${skipped#"$rb_skip0"}
  case " $rb_added " in
    *" source "*|*" source_ns "*|*" bindfail "*)
      rb_report=gone
      if sandbox_unmount "$rb_pid" "$rb_tgt"; then
        fixed=$rb_fixed0
        if [ -n "$rb_repbak" ]; then mv -f "$rb_repbak" "$REP" 2>/dev/null; else rm -f "$REP" 2>/dev/null; fi
        if [ -n "$rb_listbak" ]; then mv -f "$rb_listbak" "$FIXED_LIST" 2>/dev/null; else rm -f "$FIXED_LIST" 2>/dev/null; fi
        if sandbox_restore_root; then
          say "  共享目录源不可见，回滚沙箱 bind（重启应用后由 SI 重建共享目录）"
        else
          rb_report=stale
        fi
      else
        say "  共享目录源不可见，但回滚未卸干净（target 仍有挂载），保留现状"
        skipped="$skipped rollback"
        rb_report=stale
        rm -f "$rb_repbak" "$rb_listbak" 2>/dev/null
      fi
      if [ "$rb_report" = stale ]; then
        sand_report stale "$rb_pkg"
        return 4
      fi
      rep_add_pkg "$rb_pkg" "$SAND_KEY" failed "$rb_ns"
      sand_report_gone "$rb_pkg" shared
      return 1
      ;;
  esac
  rm -f "$rb_repbak" "$rb_listbak" 2>/dev/null

  # 沙箱本身算一条 fixed；同包多 PID 每个 namespace 都要 bind，但只计一次。
  if ! grep -qxF "$rb_pkg|$rb_ns|$SAND_KEY" "$FIXED_LIST" 2>/dev/null; then
    fixed=$((fixed + 1))
    SAND_REBUILT=$((SAND_REBUILT + 1))
    printf '%s|%s|%s\n' "$rb_pkg" "$rb_ns" "$SAND_KEY" >> "$FIXED_LIST" 2>/dev/null
  fi
  say "重建沙箱: $rb_pkg (pid $rb_pid)"
  sand_report rebuilt "$rb_pkg"
  return 0
}

flush_proc() {
  if [ -n "$need" ]; then
    broken=$((broken + 1))
    names=""
    for tok in $need_meta; do n=${tok%%=*}; names="$names $n"; done
    say "修复: $pkg (pid $pid, ${age}s):$names"
    if [ "$DRY" = 0 ]; then
      for tok in $need_meta; do
        n=${tok%%=*}; act=${tok#*=}
        repair_one "$n" "$act"
      done
    fi
  elif [ "$proc_broken" = 1 ]; then
    broken=$((broken + 1))
  fi
  need=""; need_meta=""; proc_broken=0
}

while IFS='|' read -r tag f1 f2 f3 f4 f5 f6 f7; do
  case "$tag" in
    F)
      FUSEDEV=$f1
      # 记录本轮宿主 FUSE 设备号（排障用）；dry-run 不写状态，值没变也不写。
      if [ "$DRY" = 0 ]; then
        _fd=""
        [ -r "$FUSE_DEV" ] && read -r _fd < "$FUSE_DEV" 2>/dev/null
        [ "$_fd" = "$FUSEDEV" ] || printf '%s\n' "$FUSEDEV" > "$FUSE_DEV" 2>/dev/null
      fi
      ;;
    K)
      # 合法沙箱证据：登记 pkg/boot/ns/SB + 进程 uid/starttime。
      # -n 不写盘，但同样登记到内存，保证同一轮后续 G 的资格判断与真跑一致。
      if [ "$DRY" = 0 ]; then
        kns=$(ns_of "$f1")
        seen_add "$f2" "$kns" "$f3" "$f5" "$f4"
        # 紧接着的 I 行是同一个进程：ns 读一次就够，也作为动手前的比对基准。
        kp_pid=$f1; kp_ns=$kns
      else
        seen_mem_add "$f2" "$(ns_of "$f1")" "$f3" "$f5" "$f4"
      fi
      ;;
    G)
      flush_proc
      gpkg=$f4; gpid=$f1; guid=$f2
      gns=$(ns_of "$gpid")
      # has-storage（G 行末列）：应用 ns 里连存储根都没有的进程不是隔离对象。
      ghasst=${f7:-1}
      pid_start=$f5; pid_uid=$f6; pid_ns=$gns
      if [ "$DRY" = 1 ]; then
        # 体检与真跑用同一套判定：有资格重建的进程才报告（isolated 在扫描阶段已过滤）。
        # 从未隔离过/旧 boot 证据/isolated 的进程保持静默；has-storage=0 且无本 boot
        # seen 证据时与真跑一样报 na（不计 broken），有 seen 证据则照常报需修复。
        if sandbox_eligible "$gpid" "$guid" "$gpkg" "$gns"; then
          if [ "$ghasst" = 0 ] && ! seen_cur_boot_any "$gpkg"; then
            skipped="$skipped na"
          else
            broken=$((broken + 1))
            if sandbox_stack_blocked "$gpid" "$gpkg" "$gns"; then
              skipped="$skipped sandbox_skip"
            else
              skipped="$skipped sandbox_gone"
              say "  跳过 $gpkg（沙箱丢失，体检不重建）"
            fi
          fi
        fi
      else
        rebuild_sandbox "$gpid" "$guid" "$gpkg" "$gns" "$ghasst"
        case $? in
          0) broken=$((broken + 1)) ;;
          1) broken=$((broken + 1)); skipped="$skipped sandbox_gone" ;;
          3) broken=$((broken + 1)); skipped="$skipped sandbox_skip" ;;
          4) broken=$((broken + 1)); skipped="$skipped sandbox_stale" ;;
          # na：isolated/无 storage，不是隔离对象；不写退避、不计 broken，只报一次 na。
          5) skipped="$skipped na" ;;
        esac
      fi
      ;;
    A)
      flush_proc
      say "  允许: $f1 -> $f2"
      ;;
    S)
      flush_proc
      case "$f2" in
        disabled) skipped="$skipped disabled" ;;
        identity)
          skipped="$skipped identity"
          sand_report stale "$f1"
          say "  跳过 $f1（沙箱根属于 ${f3:-?}，身份不符）"
          ;;
        layer)
          skipped="$skipped layer"
          say "  跳过 $f1（沙箱层 $f3 ≠ FUSE 层 $f4）"
          ;;
      esac
      ;;
    RS)
      # 目标栈不是“只有一层本包沙箱”：可能是回滚失败留下的叠层，或旧根又盖了回来。
      # 这不是模块能原地修的，保留现状并提示重启应用；不登记 K。
      flush_proc
      sand_report stale "$f4"
      case "$f5" in
        ''|*[!0-9]*) rsn=0 ;;
        *) rsn=$f5 ;;
      esac
      if [ "$rsn" -gt 1 ]; then
        skipped="$skipped rollback"
        say "  跳过 $f4（target 叠了 $rsn 层挂载，栈顶 ${f6:-?}，残留未卸干净，需要重启应用）"
      else
        skipped="$skipped sandbox_stale"
        say "  跳过 $f4（target 栈顶 ${f6:-?} 不是本包沙箱 ${f7:-?}，需要重启应用）"
      fi
      ;;
    ST)
      # 旧 FUSE 设备已不在宿主：应用 namespace 里的沙箱是僵死挂载。
      # 跨 namespace bind 做不到，卸掉旧挂载也拿不到新 FUSE，只能提示重启应用。
      # 不计 broken：这不是模块能修的目标，只提示用户重启应用。
      flush_proc
      skipped="$skipped sandbox_stale"
      sand_report stale "$f4"
      say "  跳过 $f4（沙箱僵死：旧 FUSE 设备 ${f5:-?} 已失效，需要重启应用）"
      ;;
    I)
      flush_proc
      pid=$f1; age=$f2; pkg=$f3; mp=$f4; pid_start=$f5; pid_uid=$f6; sbpath=$f7
      if [ "$DRY" = 0 ]; then
        if [ "$kp_pid" = "$pid" ] && [ -n "$kp_ns" ]; then pid_ns=$kp_ns
        else pid_ns=$(ns_of "$pid")
        fi
      fi
      ;;
    T)
      kind=$f2; n=$f3; act=$f4
      case "$act" in
        0) ;;
        s)
          skipped="$skipped layer"
          say "  跳过 $n（挂载在其他层，不动）"
          ;;
        churn|b|r|retry)
          # 需要补挂时锚点目录必须存在；缺失不是“无事可做”，报 target_missing
          # 并计入 broken，日志写出缺的是哪个目录。
          _tmiss=""
          if [ "$kind" = "a" ]; then
            [ -d "$sbpath/$n" ] || _tmiss="$sbpath/$n"
          elif [ ! -d "$sbpath/${n%/*}" ]; then
            _tmiss="$sbpath/${n%/*}"
          elif [ ! -d "$DATA_ROOT/media/0/$n" ]; then
            _tmiss="$DATA_ROOT/media/0/$n"
          fi
          if [ -n "$_tmiss" ]; then
            proc_broken=1
            skipped="$skipped target_missing"
            say "  跳过 $n（锚点目录缺失：$_tmiss）"
            continue
          fi
          proc_broken=1
          if [ "$act" = "churn" ]; then
            skipped="$skipped churn"
            say "  跳过 $n（频繁被拆，熔断）"
          else
            need="$need $n"
            need_meta="$need_meta $n=$act"
          fi
          ;;
      esac
      ;;
    C)
      churn_del "$f1" "$f2"
      ;;
    N)
      churn_put "$f1" "$f2" "$f3" "$f4"
      ;;
    Z)
      checked=$f1; young=$f2; retry_in=$f4
      # 同包多 PID 时，retry 失败会在 shell 里即时累加 churn，而 Z 行是扫描时的计数；
      # 直接赋值会把本轮新熔断的目标抹成 0。扫描时已 churn 的目标不会再进 repair，
      # 两处计的是不同目标，所以累加；.churn 文件行为不变。
      case "$f3" in ''|*[!0-9]*) f3=0 ;; esac
      churn=$((churn + f3))
      flush_proc
      if [ "$BOFF_IN" -gt 0 ] && { [ "$retry_in" -eq 0 ] || [ "$BOFF_IN" -lt "$retry_in" ]; }; then
        retry_in=$BOFF_IN
      fi
      ;;
  esac
done < "$OUTF"

say "----"
say "检查 $checked 个已隔离进程，$broken 个需修复，补/重挂 $fixed 条（young=$young）"

tags=""
for t in $skipped; do
  case " +$tags+" in *"+$t+"*) ;; *) if [ -z "$tags" ]; then tags=$t; else tags="$tags+$t"; fi ;; esac
done
set -- "$checked" "$broken" "$fixed" "$young"
case "$churn" in ''|*[!0-9]*) churn=0 ;; esac
[ "$churn" -gt 0 ] && set -- "$@" "churn=$churn"
case "$retry_in" in ''|*[!0-9]*) retry_in=0 ;; esac
[ "$retry_in" -gt 0 ] && set -- "$@" "retry=$retry_in"
[ "$SAND_REBUILT" -gt 0 ] 2>/dev/null && set -- "$@" "sandbox=$SAND_REBUILT"
[ -n "$tags" ] && set -- "$@" "skipped=$tags"
result_line "$@"
exit 0
