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
# 应用 namespace 自己的存储视图（FUSE 重挂后 /mnt/user/0/emulated 可能不在应用 ns 里）。
ALT_ROOT=/storage/emulated/0
if [ "$SI_TEST" = 1 ]; then
  [ -n "$SI_TEST_DATA" ] && DATA_ROOT=$SI_TEST_DATA
  [ -n "$SI_TEST_SRC" ] && SRC_ROOT=$SI_TEST_SRC
  [ -n "$SI_TEST_ALT" ] && ALT_ROOT=$SI_TEST_ALT
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
REP=$RC/.repairs
CH=$RC/.churn
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
  rm -f "$PARSED" "$SRC" "$FIXED_LIST" "$FIXED_LIST.tmp" "$SEEN_TMP" "$CACHE.tmp.$$" "$REP.tmp.$$" "$CH.tmp.$$" 2>/dev/null
  [ "$DRY" = 1 ] && [ -e "$OUTF" ] && rm -f "$OUTF" 2>/dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

trim_state() {
  # .repairs 只留最近 1 小时/200 行；.churn 是进程内状态，重启清零（否则一次抖动永久 block）。
  if [ -s "$REP" ]; then
    awk -v now="$NOW" '
      { if (($1 + 0) >= now - 3600) b[++n] = $0 }
      END { s = n - 199; if (s < 1) s = 1; for (i = s; i <= n; i++) print b[i] }
    ' "$REP" > "$REP.tmp.$$" 2>/dev/null && mv -f "$REP.tmp.$$" "$REP" 2>/dev/null
  fi
  rm -f "$CH" 2>/dev/null
  rm -f "$RC"/.si-conf.* "$RC"/.si-parsed.* "$RC"/.si-allow.* \
        "$RC"/.si-cand.* "$RC"/.si-ps.* "$RC"/.si-fixed.* "$RC"/.si-out.dry.* \
        "$RC"/.conf.cache.tmp.* 2>/dev/null
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
    rm -rf "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
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

# .sandbox_seen：每行 pkg|boot|mnt_ns|SB（“曾经识别到合法沙箱”的证据）。
# 同 pkg 同 boot 同 namespace 只保留一条（SB 变化时更新）；最多 200 行保留最近。
load_seen() {
  SEEN_LIST=""; SEEN_N=0; SEEN_CUR=0
  [ -r "$SANDBOX_SEEN" ] || return 0
  while IFS= read -r _sl; do
    [ -n "$_sl" ] || continue
    SEEN_LIST="$SEEN_LIST $_sl"
    SEEN_N=$((SEEN_N + 1))
    _oldifs=$IFS; IFS='|'; set -- $_sl; IFS=$_oldifs
    [ "${2:-}" = "$BOOT_ID" ] && SEEN_CUR=$((SEEN_CUR + 1))
  done 2>/dev/null < "$SANDBOX_SEEN"
}
seen_match() {   # pkg ns（只看本 boot）
  _sm_pfx=" $1|$BOOT_ID|$2|"
  case " $SEEN_LIST " in *"$_sm_pfx"*) return 0 ;; esac
  return 1
}
seen_sb() {      # pkg ns -> 本 boot 记录的 SB
  _ss_pkg=$1; _ss_ns=$2
  for _se in $SEEN_LIST; do
    _eifs=$IFS; IFS='|'; set -- $_se; IFS=$_eifs
    if [ "${1:-}" = "$_ss_pkg" ] && [ "${2:-}" = "$BOOT_ID" ] && [ "${3:-}" = "$_ss_ns" ]; then
      printf '%s\n' "${4:-}"
      return 0
    fi
  done
  return 1
}
seen_add() {     # pkg ns sb
  _sa=$1; _sn=$2; _ss=$3
  case "$_sa" in ''|*[!A-Za-z0-9_.-]*) return 0 ;; esac
  case "$_ss" in ''|*[!A-Za-z0-9_./-]*) return 0 ;; esac
  _old=$(seen_sb "$_sa" "$_sn" 2>/dev/null)
  [ "$_old" = "$_ss" ] && return 0
  _list=""; _n=0
  for _se in $SEEN_LIST; do
    case "$_se" in "$_sa|$BOOT_ID|$_sn|"*) continue ;; esac
    _list="$_list $_se"; _n=$((_n + 1))
  done
  _list="$_list $_sa|$BOOT_ID|$_sn|$_ss"; _n=$((_n + 1))
  SEEN_LIST=$_list; SEEN_N=$_n
  { for _se in $SEEN_LIST; do printf '%s\n' "$_se"; done; } > "$SEEN_TMP" 2>/dev/null \
    && mv -f "$SEEN_TMP" "$SANDBOX_SEEN" 2>/dev/null || return 0
  if [ "$_n" -gt 200 ]; then
    tail -n 200 "$SANDBOX_SEEN" > "$SEEN_TMP" 2>/dev/null \
      && mv -f "$SEEN_TMP" "$SANDBOX_SEEN" 2>/dev/null
    load_seen
  fi
}
load_seen
[ "$DRY" = 0 ] && : > "$SAND_REPORT" 2>/dev/null
ns_of() { readlink "$PROC/$1/ns/mnt" 2>/dev/null; }
# 重建资格：本 boot 同 pkg 同 ns 的 seen，或（没有 cross-boot 旧证据时）源存在且属主匹配。
sandbox_eligible() {   # pid uid pkg ns
  seen_match "$3" "$4" && return 0
  { [ "$SEEN_N" -eq 0 ] || [ "$SEEN_CUR" -gt 0 ]; } || return 1
  sandbox_pick "$1" "$2" "$3" "$4" 0 >/dev/null 2>&1
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
sand_report() {  # tag pkg（只写非 dry；daemon 读）
  [ "$DRY" = 1 ] && return 0
  printf '%s %s\n' "$1" "$2" >> "$SAND_REPORT" 2>/dev/null
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
if [ -s "$CACHE" ] && [ -n "$CONF_STAT" ]; then
  read -r chdr < "$CACHE" 2>/dev/null
  [ "$chdr" = "#SI2 $CONF_STAT" ] && cache_ok=1
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

  printf '#SI2 %s\n' "$META1" > "$CACHE.tmp.$$" 2>/dev/null || {
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
    -v rep="$REP" -v ch="$CH" -v dataroot="$DATA_ROOT" -v hostmi="$HOSTMI" '
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
    if (TC[t] == 0) return "b"
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
    # 宿主基准取 init 的 mount ns；同时收全部设备号，区分旧 FUSE 会话/别的层。
    while ((getline l < hostmi) > 0) {
      split(l, z, " ")
      if (z[3] != "") HOSTDEV[z[3]] = 1
      if (z[5] == "/storage/emulated" && FDEV == "") FDEV = z[3]
      if (z[5] == "/mnt/user/0/emulated" && HOSTM == "") HOSTM = z[3]
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
    if (int(uid / 100000) != 0) next
    if (pkg !~ ("^(" pkgs ")(:|$)")) next

    mi = proc "/" pid "/mountinfo"
    r = (getline first < mi)
    if (r < 0) { close(mi); next }
    checked++
    age = secs(et)
    if (age < amin) { young++; close(mi); next }

    if (!(pkg in EN)) { close(mi); next }
    val = EN[pkg]; i = index(val, ":")
    en = substr(val, 1, i - 1); allow = substr(val, i + 1)
    if (en != "1") { print "S|" pkg "|disabled"; close(mi); next }
    if (verbose && allow != "") print "A|" pkg "|" allow
    if (r == 0) { close(mi); next }

    SB = ""; SDEV = ""; MP = ""; SFT = ""
    APP_S = ""; APP_M = ""; APP_SFT = ""; APP_MFT = ""
    split("", TD); split("", TC)
    parse_mi(first)
    while ((getline ml < mi) > 0) parse_mi(ml)
    close(mi)
    if (SB == "") {
      # 应用 /storage（或 /mnt）还是旧 FUSE（分叉）：跨 ns 修不了，只报僵死。
      if (APP_S != "" && APP_S != FDEV && APP_SFT == "fuse") print "ST|" pid "|" uid "|" age "|" pkg "|" APP_S
      else if (APP_S == "" && APP_M != "" && APP_M != HOSTM && APP_MFT == "fuse") print "ST|" pid "|" uid "|" age "|" pkg "|" APP_M
      else print "G|" pid "|" uid "|" age "|" pkg
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
    if (!(SDEV == FDEV && (APP_S == "" || APP_S == FDEV))) {
      # 旧 FUSE 会话已从宿主消失、沙箱本身又是 fuse：僵死挂载，跨 namespace 无法修。
      # 其它情况（宿主里仍有该设备，或根本不是 FUSE）保持原来的 layer 语义。
      if (SFT == "fuse" && !(SDEV in HOSTDEV)) print "ST|" pid "|" uid "|" age "|" pkg "|" SDEV
      else print "S|" pkg "|layer|" SDEV "|" FDEV
      next
    }
    if (SB ~ /^\/media\//) sbpath = dataroot "/media" substr(SB, 7)
    else if (SB ~ /^\/[0-9]+\/Android\/data\//) sbpath = dataroot "/media" SB
    else next

    # 合法沙箱（身份/层都通过、路径形态可解释）→ 供 shell 登记身份证据。
    print "K|" pid "|" pkg "|" SB
    print "I|" pid "|" age "|" pkg "|" MP "|" sbpath

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
FUSEDEV=""; HOSTM=""
SAND_REBUILT=0
pid=""; age=""; pkg=""; mp=""; sbpath=""
need=""; need_meta=""; proc_broken=0
skipped="$EXTRA_SKIP"

rep_add() {   # $1=target $2=fixed|failed
  # 记录 bind 的实际时刻（秒.毫秒）：熔断的 <1 秒判据依赖它。
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
  echo "$_sec.$_frac $pkg $1 $2" >> "$REP" 2>/dev/null
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

  if [ ! -d "$src" ]; then
    skipped="$skipped source"
    say "  跳过 $rt（源不存在）"
    [ "$ra" = "retry" ] && { churn_put "$pkg" "$rt" block "$((NOW + 3600))"; churn=$((churn + 1)); skipped="$skipped churn"; echo "N|$pkg|$rt|block|$((NOW + 3600))"; }
    return 0
  fi
  if ! timeout 2 nsenter -t "$pid" -m -- test -d "$src" </dev/null 2>/dev/null; then
    skipped="$skipped source_ns"
    say "  跳过 $rt（应用 namespace 里看不到源）"
    [ "$ra" = "retry" ] && { churn_put "$pkg" "$rt" block "$((NOW + 3600))"; churn=$((churn + 1)); skipped="$skipped churn"; echo "N|$pkg|$rt|block|$((NOW + 3600))"; }
    return 0
  fi

  set -- $(stat_of "$tgt"); c=${1:-}; k=${2:-0}
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
    rep_add "$rt" failed
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
    # 同包多 PID 共用 (pkg,target)：每个 PID 都要实际修并校验，但成功只计一次。
    if ! grep -qxF "$pkg|$rt" "$FIXED_LIST" 2>/dev/null; then
      fixed=$((fixed + 1))
      rep_add "$rt" fixed
      printf '%s|%s\n' "$pkg" "$rt" >> "$FIXED_LIST" 2>/dev/null
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
    rep_add "$rt" failed
    [ "$ra" = "retry" ] && { churn_put "$pkg" "$rt" block "$((NOW + 3600))"; churn=$((churn + 1)); skipped="$skipped churn"; echo "N|$pkg|$rt|block|$((NOW + 3600))"; }
  fi
}

# 选一个可用的沙箱源：先 K 记录的 SB 推导路径，再 pkg/shared-pkg 的
# sdcard/cache 变体（宿主 FUSE 视图 → 应用 /storage 视图）。
# mode=0 只查宿主侧存在/属主（给 dry-run 判定资格）；mode=1 还要求应用 ns 可见、
# 并在应用 ns 里统计属主。成功输出 "<sandbox-id>|<path>"，失败输出原因。
sandbox_pick() {   # pid uid pkg ns mode
  sp_pid=$1; sp_uid=$2; sp_pkg=$3; sp_ns=$4; sp_mode=$5
  sp_exists=0; sp_owner_bad=0; sp_hidden=0; sp_seen_paths=""
  sp_list=""
  sp_sb=$(seen_sb "$sp_pkg" "$sp_ns" 2>/dev/null)
  if [ -n "$sp_sb" ]; then sp_list=$(sb_to_src "$sp_sb"); fi
  for sp_id in "$sp_pkg" "shared-$sp_pkg"; do
    for sp_root in "$SRC_ROOT/0" "$ALT_ROOT"; do
      sp_list="$sp_list
$sp_root/Android/data/$sp_id/sdcard
$sp_root/Android/data/$sp_id/cache/sdcard"
    done
  done
  while IFS= read -r sp_src; do
    [ -n "$sp_src" ] || continue
    case " $sp_seen_paths " in *" $sp_src "*) continue ;; esac
    sp_seen_paths="$sp_seen_paths $sp_src"
    if [ -L "$sp_src" ] || [ ! -d "$sp_src" ]; then continue; fi
    sp_exists=1
    sp_id2=${sp_src#*/Android/data/}
    sp_id2=${sp_id2%%/*}
    [ -n "$sp_id2" ] || continue
    if [ "$sp_mode" = 1 ]; then
      if ! timeout 2 nsenter -t "$sp_pid" -m -- test -d "$sp_src" </dev/null 2>/dev/null; then
        sp_hidden=1
        continue
      fi
      sp_owner=$(sandbox_owner_ns "$sp_pid" "$sp_src")
    else
      sp_owner=$(sandbox_owner "$sp_src")
    fi
    if [ "$sp_owner" != "$sp_uid" ]; then sp_owner_bad=1; continue; fi
    printf '%s|%s\n' "$sp_id2" "$sp_src"
    return 0
  done <<EOF
$sp_list
EOF
  if [ "$sp_exists" = 0 ]; then printf 'missing\n'
  elif [ "$sp_owner_bad" = 1 ]; then printf 'owner\n'
  else printf 'hidden\n'
  fi
  return 1
}

# 沙箱丢失重建：只在“曾经见过沙箱，或沙箱目录存在且属主匹配”的进程 ns 里补沙箱根。
# 返回 0=已重建 1=失败（报 sandbox_gone） 2=无需动作/从未隔离（静默）。
rebuild_sandbox() {   # pid uid pkg ns
  rb_pid=$1; rb_uid=$2; rb_pkg=$3; rb_ns=$4
  rb_tgt=/storage/emulated/0
  rb_mi=$PROC/$rb_pid/mountinfo

  # 1) 资格：本 boot seen 身份，或没有旧 boot 证据时“源存在且属主==uid”。
  if ! sandbox_eligible "$rb_pid" "$rb_uid" "$rb_pkg" "$rb_ns"; then
    return 2
  fi
  rb_pick=$(sandbox_pick "$rb_pid" "$rb_uid" "$rb_pkg" "$rb_ns" 1)
  rb_rc=$?
  if [ "$rb_rc" -ne 0 ]; then
    rb_reason=$rb_pick
    case "$rb_reason" in
      missing) say "  跳过沙箱 $rb_pkg（源不存在或不是目录）" ;;
      owner)   say "  跳过沙箱 $rb_pkg（属主与进程 uid $rb_uid 不符）" ;;
      hidden)  say "  跳过沙箱 $rb_pkg（应用 namespace 看不到源）" ;;
      *)       say "  跳过沙箱 $rb_pkg（源不可用）" ;;
    esac
    sand_report gone "$rb_pkg"
    return 1
  fi
  _rb_ifs=$IFS; IFS='|'; set -- $rb_pick; IFS=$_rb_ifs
  rb_id=${1:-}; rb_src=${2:-}
  rb_used_alt=0
  case "$rb_src" in "$SRC_ROOT"/*) ;; *) rb_used_alt=1 ;; esac
  [ "$rb_used_alt" = 1 ] && say "  沙箱源改用应用视图: $rb_src"

  # 2) 目标必须存在，且当前不是沙箱；普通 FUSE 根可先卸掉再 bind。
  if ! timeout 2 nsenter -t "$rb_pid" -m -- test -d "$rb_tgt" </dev/null 2>/dev/null; then
    say "  跳过沙箱 $rb_pkg（目标不存在）"
    sand_report gone "$rb_pkg"
    return 1
  fi
  mi=$rb_mi
  set -- $(stat_src_of "$rb_tgt"); rb_dev=${1:-}; rb_n=${2:-0}; rb_s=${3:-}
  if [ "$rb_n" -gt 0 ]; then
    if sandbox_src_match "$rb_s" "$rb_id" \
       || sandbox_src_match "$rb_s" "$rb_pkg" \
       || sandbox_src_match "$rb_s" "shared-$rb_pkg"; then
      say "  跳过沙箱 $rb_pkg（目标已是沙箱，无需重建）"
      return 2
    fi
    if [ "$rb_n" = 1 ] && [ "$rb_s" = "/" ] && [ "$rb_dev" = "$FUSEDEV" ]; then
      umount_one "$rb_pid" "$rb_tgt" >/dev/null 2>&1
      set -- $(stat_src_of "$rb_tgt"); rb_dev=${1:-}; rb_n=${2:-0}; rb_s=${3:-}
      say "  目标 /storage/emulated/0 是普通 FUSE 根，已卸下后重挂沙箱"
    fi
    if [ "$rb_n" -gt 0 ]; then
      say "  跳过沙箱 $rb_pkg（目标已有其他挂载 dev=${rb_dev:-?} src=$rb_s）"
      sand_report gone "$rb_pkg"
      return 1
    fi
  fi

  err=$(bind_mount "$rb_pid" "$rb_src" "$rb_tgt" 2>&1)
  set -- $(stat_src_of "$rb_tgt"); rb_dev=${1:-}; rb_n=${2:-0}; rb_s=${3:-}
  rb_ok=0
  sandbox_src_match "$rb_s" "$rb_id" || rb_ok=1
  [ "$rb_dev" = "$FUSEDEV" ] || rb_ok=1
  if [ "$rb_n" -gt 1 ] && [ "$rb_ok" -ne 0 ]; then
    # count>1 可能是 SI 并发挂载：source/dev 不对时绝不盲目 umount。
    [ -n "$err" ] && say "  沙箱 bind 输出: $err"
    say "  跳过沙箱 $rb_pkg（并发挂载 dev=${rb_dev:-?} n=$rb_n src=${rb_s:-?}，不 umount）"
    sand_report gone "$rb_pkg"
    return 1
  fi
  [ "$rb_n" = "1" ] || [ "$rb_n" -gt 1 ] || rb_ok=1
  if [ "$rb_ok" -ne 0 ]; then
    [ -n "$err" ] && say "  沙箱 bind 输出: $err"
    say "  跳过沙箱 $rb_pkg（bind 后校验失败 dev=${rb_dev:-?} n=$rb_n src=${rb_s:-?}，已回滚）"
    if [ "$rb_n" -le 1 ]; then umount_one "$rb_pid" "$rb_tgt" >/dev/null 2>&1; fi
    sand_report gone "$rb_pkg"
    return 1
  fi
  if [ "$rb_n" -gt 1 ]; then
    say "  警告 沙箱 $rb_pkg: 检测到 $rb_n 条并发挂载，保留现状"
  fi
  [ -n "$err" ] && say "  警告 沙箱 $rb_pkg: 命令有输出但挂载校验通过（$err）"
  # bind 后必须在应用 ns 里确认 target 可读，防“挂上了但一读就 EIO”。
  if ! timeout 2 nsenter -t "$rb_pid" -m -- test -r "$rb_tgt" </dev/null 2>/dev/null; then
    say "  跳过沙箱 $rb_pkg（bind 后在应用内不可读，已回滚）"
    umount_one "$rb_pid" "$rb_tgt" >/dev/null 2>&1
    sand_report gone "$rb_pkg"
    return 1
  fi

  # 3) 复用 repair_one 补 allow 目录与 Android/{data,media,obb}/<pkg>；
  #    共享目录源不可见时不能留下“空沙箱”，回滚刚 bind 的沙箱。
  pid=$rb_pid; pkg=$rb_pkg; mp=$rb_tgt; sbpath=$rb_src; mi=$rb_mi
  rb_fixed0=$fixed
  rb_repn=0
  [ -f "$REP" ] && rb_repn=$(wc -l < "$REP" 2>/dev/null)
  case "$rb_repn" in ''|*[!0-9]*) rb_repn=0 ;; esac
  rb_listn=0
  [ -f "$FIXED_LIST" ] && rb_listn=$(wc -l < "$FIXED_LIST" 2>/dev/null)
  case "$rb_listn" in ''|*[!0-9]*) rb_listn=0 ;; esac
  rb_skip0=$skipped
  rb_allow=$(allow_of "$rb_id")
  [ -n "$rb_allow" ] || rb_allow=$(allow_of "$rb_pkg")
  [ -n "$rb_allow" ] || rb_allow=$(allow_of "shared-$rb_pkg")
  for rb_d in $rb_allow; do
    [ -d "$sbpath/$rb_d" ] || continue
    rb_act=$(target_action_shell "$mp/$rb_d")
    case "$rb_act" in
      0) continue ;;
      s) skipped="$skipped layer"; say "  跳过 $rb_d（挂载在其他层，不动）"; continue ;;
      *) repair_one "$rb_d" b ;;
    esac
  done
  for rb_d in "Android/data/$rb_pkg" "Android/media/$rb_pkg" "Android/obb/$rb_pkg"; do
    [ -d "$sbpath/${rb_d%/*}" ] || continue
    [ -d "$DATA_ROOT/media/0/$rb_d" ] || continue
    rb_act=$(target_action_shell "$mp/$rb_d")
    case "$rb_act" in
      0) continue ;;
      s) skipped="$skipped layer"; say "  跳过 $rb_d（挂载在其他层，不动）"; continue ;;
      *) repair_one "$rb_d" b ;;
    esac
  done
  rb_added=${skipped#"$rb_skip0"}
  case " $rb_added " in
    *" source_ns "*)
      say "  共享目录源不可见，回滚沙箱 bind（重启应用后由 SI 重建共享目录）"
      umount_one "$rb_pid" "$rb_tgt" >/dev/null 2>&1
      fixed=$rb_fixed0
      if [ "$rb_repn" -gt 0 ]; then
        head -n "$rb_repn" "$REP" > "$REP.tmp.$$" 2>/dev/null && mv -f "$REP.tmp.$$" "$REP" 2>/dev/null
      else
        : > "$REP" 2>/dev/null
      fi
      if [ "$rb_listn" -gt 0 ]; then
        head -n "$rb_listn" "$FIXED_LIST" > "$FIXED_LIST.tmp" 2>/dev/null && mv -f "$FIXED_LIST.tmp" "$FIXED_LIST" 2>/dev/null
      else
        : > "$FIXED_LIST" 2>/dev/null
      fi
      sand_report gone "$rb_pkg"
      return 1
      ;;
  esac

  # 沙箱本身算一条 fixed；同包多 PID 每个 namespace 都要 bind，但只计一次。
  if ! grep -qxF "$rb_pkg|sandbox" "$FIXED_LIST" 2>/dev/null; then
    fixed=$((fixed + 1))
    SAND_REBUILT=$((SAND_REBUILT + 1))
    printf '%s|%s\n' "$rb_pkg" "sandbox" >> "$FIXED_LIST" 2>/dev/null
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

while IFS='|' read -r tag f1 f2 f3 f4 f5; do
  case "$tag" in
    F)
      FUSEDEV=$f1; HOSTM=$f2
      # 记录本轮宿主 FUSE 设备号（排障用）；dry-run 不写状态，值没变也不写。
      if [ "$DRY" = 0 ]; then
        _fd=""
        [ -r "$FUSE_DEV" ] && read -r _fd < "$FUSE_DEV" 2>/dev/null
        [ "$_fd" = "$FUSEDEV" ] || printf '%s\n' "$FUSEDEV" > "$FUSE_DEV" 2>/dev/null
      fi
      ;;
    K)
      # 合法沙箱证据：登记 pkg/boot/ns/SB；dry-run 保持只读，不登记。
      if [ "$DRY" = 0 ]; then
        kns=$(ns_of "$f1")
        seen_add "$f2" "$kns" "$f3"
      fi
      ;;
    G)
      flush_proc
      gpkg=$f4; gpid=$f1; guid=$f2
      gns=$(ns_of "$gpid")
      if [ "$DRY" = 1 ]; then
        # 体检只报告“有资格重建”的进程；从未隔离过的（无源/属主不符/旧 boot 证据）保持静默。
        if sandbox_eligible "$gpid" "$guid" "$gpkg" "$gns"; then
          broken=$((broken + 1))
          skipped="$skipped sandbox_gone"
          say "  跳过 $gpkg（沙箱丢失，体检不重建）"
        fi
      else
        rebuild_sandbox "$gpid" "$guid" "$gpkg" "$gns"
        case $? in
          0) broken=$((broken + 1)) ;;
          1) broken=$((broken + 1)); skipped="$skipped sandbox_gone" ;;
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
          say "  跳过 $f1（沙箱根属于 ${f3:-?}，身份不符）"
          ;;
        layer)
          skipped="$skipped layer"
          say "  跳过 $f1（沙箱层 $f3 ≠ FUSE 层 $f4）"
          ;;
      esac
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
      pid=$f1; age=$f2; pkg=$f3; mp=$f4; sbpath=$f5
      ;;
    T)
      kind=$f2; n=$f3; act=$f4
      if [ "$kind" = "a" ]; then
        [ -d "$sbpath/$n" ] || continue
      else
        [ -d "$sbpath/${n%/*}" ] || continue
        [ -d "$DATA_ROOT/media/0/$n" ] || continue
      fi
      case "$act" in
        0) ;;
        s)
          skipped="$skipped layer"
          say "  跳过 $n（挂载在其他层，不动）"
          ;;
        churn)
          proc_broken=1
          skipped="$skipped churn"
          say "  跳过 $n（频繁被拆，熔断）"
          ;;
        b|r|retry)
          proc_broken=1
          need="$need $n"
          need_meta="$need_meta $n=$act"
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
      checked=$f1; young=$f2; churn=$f3; retry_in=$f4
      flush_proc
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
