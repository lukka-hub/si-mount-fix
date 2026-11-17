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
  rm -f "$PARSED" "$SRC" "$FIXED_LIST" "$CACHE.tmp.$$" "$REP.tmp.$$" "$CH.tmp.$$" 2>/dev/null
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

"$PS_BIN" -A -o pid,uid,etime,args 2>/dev/null | awk -v cache="$CACHE_USE" -v proc="$PROC" \
    -v now="$NOW" -v nowms="$NOW_MS" -v amin="$AGE_MIN" -v verbose="$VERBOSE" -v dry="$DRY" \
    -v rep="$REP" -v ch="$CH" -v dataroot="$DATA_ROOT" '
  function secs(e,  p,n,t,d) {
    d = 0
    if (index(e, "-") > 0) { split(e, p, "-"); d = p[1] + 0; e = p[2] }
    n = split(e, t, ":")
    if (n == 3) return d * 86400 + t[1] * 3600 + t[2] * 60 + t[3]
    if (n == 2) return d * 86400 + t[1] * 60 + t[2]
    return d * 86400 + t[1]
  }
  function parse_mi(l,  f) {
    # 大多数 mountinfo 行无关，先用 C 级 substring 过滤再 split。
    if (index(l, "/storage/emulated/") == 0 && index(l, "/Android/data/") == 0) return
    split(l, f, " ")
    if (f[4] ~ /^\/(media\/)?[0-9]+\/Android\/data\/.+\/(cache\/)?sdcard$/ && f[5] ~ /^\/storage\/emulated\/[0-9]+$/) {
      SB = f[4]; SDEV = f[3]; MP = f[5]
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
    FDEV = ""
    while ((getline l < (proc "/self/mountinfo")) > 0) {
      split(l, z, " ")
      if (z[5] == "/mnt/user/0/emulated" || z[5] == "/storage/emulated") { FDEV = z[3]; break }
    }
    close(proc "/self/mountinfo")
    if (FDEV == "") { print "F|"; FUSE_BAD = 1; exit 9 }
    print "F|" FDEV
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

    SB = ""; SDEV = ""; MP = ""
    split("", TD); split("", TC)
    parse_mi(first)
    while ((getline ml < mi) > 0) parse_mi(ml)
    close(mi)
    if (SB == "") next

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
    if (SDEV != FDEV) {
      print "S|" pkg "|layer|" SDEV "|" FDEV
      next
    }
    if (SB ~ /^\/media\//) sbpath = dataroot "/media" substr(SB, 7)
    else if (SB ~ /^\/[0-9]+\/Android\/data\//) sbpath = dataroot "/media" SB
    else next

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
      FUSEDEV=$f1
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
[ -n "$tags" ] && set -- "$@" "skipped=$tags"
result_line "$@"
exit 0
