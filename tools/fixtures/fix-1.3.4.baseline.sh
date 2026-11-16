#!/system/bin/sh
# source: 5718877:scripts/fix-si-mounts.sh（1.3.4 基线；equiv.test.sh 只替换固定路径常量）
# fix-si-mounts.sh v8 — 修复「存储空间隔离」丢失/挂错层的共享目录挂载
#
# 相对 v7 的性能与安全改动（按 04/02 两份审计）：
#   1) 配置只解析一次：awk 把 configuration.json + mount_dirs_templates 合成
#      "|pkg=enabled:dirs" 映射文件，循环里只做一次 grep 查表（原来每个进程重算 24 个 exec）。
#   2) 进程清单一次取全：ps -A -o pid,uid,etime,args 直接给出 uid 与存活秒数，
#      不再对每个进程 stat/cmdline 各 fork 一次；年龄检查前移，年轻进程不读 mountinfo。
#   3) 层保护：沙箱设备的设备号必须等于本机 FUSE 设备号，否则 skipped=layer，
#      绝不 umount（避免 /media 形态被"越修越坏"）。
#   4) 先验源后拆：源目录不存在就不动现有挂载。
#   5) 校验一次 awk 同时拿 dev 与条数；叠挂拆到 0 条再挂。
#
# 用法（root）：sh fix-si-mounts.sh [-n] [-q] [-v]
# 输出末行：RESULT checked=N broken=N fixed=N young=N [skipped=...] [error=...]

DRY=0; QUIET=0; VERBOSE=0
for a in "$@"; do
  case "$a" in
    -n|--dry-run) DRY=1 ;;
    -q|--quiet) QUIET=1 ;;
    -v|--verbose) VERBOSE=1 ;;
  esac
done
say() { [ "$QUIET" = 1 ] || echo "$@"; }

CONF=${SI_CONF:-/data/adb/storage-isolation/configuration.json}
# 仅供自测把 /proc 换成 fixture：必须显式 SI_TEST=1，生产环境即使有残留也忽略。
PROC=/proc
if [ "$SI_TEST" = 1 ] && [ -n "$SI_PROC" ]; then
  PROC=$SI_PROC
fi
TPLJSON=""   # 先拷快照，校验完整后再算（见下）
AGE_MIN=${SI_MIN_AGE:-15}
case "$AGE_MIN" in ''|*[!0-9]*) AGE_MIN=15 ;; esac
[ "$AGE_MIN" -lt 5 ] && AGE_MIN=5
[ "$AGE_MIN" -gt 120 ] && AGE_MIN=120

# ---------- 临时目录：只用数据目录 ----------
RC=${SI_DATA:-/data/adb/si-mount-fix}
if ! mkdir -p "$RC" 2>/dev/null || [ ! -w "$RC" ]; then
  echo "无法写入 $RC" >&2
  echo "RESULT checked=0 broken=0 fixed=0 young=0 error=datadir"
  exit 3
fi
chmod 700 "$RC" 2>/dev/null

RECF=$RC/.si-recs.$$
TPLF=$RC/.si-tpl.$$
ALLOWF=$RC/.si-allow.$$
CANDF=$RC/.si-cand.$$
SRC=$RC/.si-conf.$$
CLEAN_LOCK=""

cleanup() {
  # 只删自己的锁：锁可能已被判陈旧后重抢，绝不能把别人的锁一起删掉。
  if [ -n "$CLEAN_LOCK" ] && [ "$(cat "$CLEAN_LOCK/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$CLEAN_LOCK" 2>/dev/null
  fi
  rm -f "$RECF" "$TPLF" "$ALLOWF" "$CANDF" "$SRC" 2>/dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

if [ "$DRY" = 0 ]; then
  LOCK=$RC/.si-fix.lock
  if ! mkdir "$LOCK" 2>/dev/null; then
    lp=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$lp" ] && [ -d "$PROC/$lp" ] && \
       tr '\0' ' ' < "$PROC/$lp/cmdline" 2>/dev/null | grep -q 'fix-si-mounts\.sh'; then
      echo "RESULT checked=0 broken=0 fixed=0 young=0 skipped=locked"
      exit 0
    fi
    rm -rf "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
  fi
  echo $$ > "$LOCK/pid"
  CLEAN_LOCK=$LOCK
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

# ---------- 配置：先拷一份完整快照，再一次性合成 pkg → "enabled:dirs" ----------
# SI 可能正在重写 configuration.json：直接读会拿到半截 JSON，而半截数据里
# "enabled":false 可能刚好被截掉，进而把已停用的应用当成启用去补挂载。
if ! cp -f "$CONF" "$SRC" 2>/dev/null || [ ! -s "$SRC" ]; then
  say "配置不可读，跳过本轮"
  echo "RESULT checked=0 broken=0 fixed=0 young=0 error=config"
  exit 2
fi
last=$(tr -d ' \t\r\n' < "$SRC" 2>/dev/null | tail -c 1)
if [ "$last" != "}" ]; then
  say "配置不完整（SI 正在重写？），跳过本轮"
  echo "RESULT checked=0 broken=0 fixed=0 young=0 error=config"
  exit 2
fi
TPLJSON=$(grep -o '"mount_dirs_templates":.*' "$SRC" 2>/dev/null)
[ -n "$TPLJSON" ] || say "警告：mount_dirs_templates 解析为空（配置可能是多行 JSON），模板目录会漏修"

awk '{n=split($0,a,"},{"); for(i=1;i<=n;i++) print a[i]}' "$SRC" 2>/dev/null > "$RECF"
printf '%s' "$TPLJSON" | awk '{n=split($0,a,"},{"); for(i=1;i<=n;i++) print a[i]}' 2>/dev/null > "$TPLF"

if [ ! -s "$RECF" ]; then
  say "配置不可读，跳过本轮"
  echo "RESULT checked=0 broken=0 fixed=0 young=0 error=config"
  exit 2
fi

awk -v tf="$TPLF" '
  function secs(e,  p,n,t,d) {
    d=0
    if (index(e,"-")>0) { split(e,p,"-"); d=p[1]+0; e=p[2] }
    n=split(e,t,":")
    if (n==3) return d*86400 + t[1]*3600 + t[2]*60 + t[3]
    if (n==2) return d*86400 + t[1]*60 + t[2]
    return d*86400 + t[1]
  }
  BEGIN {
    while ((getline l < tf) > 0) {
      id=""; list=""
      if (match(l, /"id":"[^"]*"/)) id = substr(l, RSTART+6, RLENGTH-7)
      if (match(l, /"list":\[[^]]*\]/)) { list = substr(l, RSTART+8, RLENGTH-9); gsub(/"/,"",list); gsub(/,/," ",list) }
      if (id != "") T[id] = list
    }
  }
  {
    n = split($0, a, "},{")
    for (i = 1; i <= n; i++) {
      r = a[i]
      if (r !~ /"mount_dirs"/) continue
      pkg = ""; if (match(r, /"package_name":"[^"]*"/)) pkg = substr(r, RSTART+16, RLENGTH-17)
      if (pkg == "") continue
      en = 1; if (r ~ /"enabled":false/) en = 0
      t = ""; if (match(r, /"template_ids":\[[^]]*\]/)) { t = substr(r, RSTART+16, RLENGTH-17); gsub(/"/,"",t) }
      c = ""; if (match(r, /"custom_dirs":\[[^]]*\]/))  { c = substr(r, RSTART+15, RLENGTH-16); gsub(/"/,"",c) }
      allow = ""
      k = split(t, x, ",")
      for (j = 1; j <= k; j++) { id = x[j]; gsub(/ /,"",id); if (id in T) allow = allow " " T[id] }
      gsub(/,/," ",c)
      allow = allow " " c
      gsub(/  +/," ",allow); sub(/^ /,"",allow)
      print "|" pkg "=" en ":" allow
      # SI 里有些记录叫 shared-com.foo（共享 uid），进程名却是 com.foo：两个 key 都登记
      if (pkg ~ /^shared-/) {
        real = pkg; sub(/^shared-/, "", real)
        print "|" real "=" en ":" allow
      }
    }
  }' "$RECF" > "$ALLOWF"

# ---------- 进程清单（一次 ps：pid / uid / 存活秒数 / 包名）----------
pkgs=$(grep -o '"package_name":"[^"]*"' "$SRC" 2>/dev/null | cut -d'"' -f4 \
       | sed 's/^shared-//' | sort -u | awk '{gsub(/\./,"\\."); print}' | tr '\n' '|' | sed 's/|$//')
if [ -z "$pkgs" ]; then
  say "配置不可读，跳过本轮"
  echo "RESULT checked=0 broken=0 fixed=0 young=0 error=config"
  exit 2
fi

PSF=$RC/.si-ps.$$
if ! ps -A -o pid,uid,etime,args > "$PSF" 2>/dev/null || [ "$(wc -l < "$PSF" 2>/dev/null || echo 0)" -lt 2 ]; then
  say "ps 不可用或输出异常，跳过本轮"
  rm -f "$PSF" 2>/dev/null
  echo "RESULT checked=0 broken=0 fixed=0 young=0 error=ps"
  exit 4
fi

awk -v re="^(${pkgs})(:|$)" '
  function secs(e,  p,n,t,d) {
    d=0
    if (index(e,"-")>0) { split(e,p,"-"); d=p[1]+0; e=p[2] }
    n=split(e,t,":")
    if (n==3) return d*86400 + t[1]*3600 + t[2]*60 + t[3]
    if (n==2) return d*86400 + t[1]*60 + t[2]
    return d*86400 + t[1]
  }
  NR>1 && $4 ~ re {
    if (int($2 / 100000) != 0) next      # 只处理主用户
    print $1, secs($3), $4
  }' "$PSF" > "$CANDF"
rm -f "$PSF" 2>/dev/null

# 本机 FUSE 设备号（用于层保护）
fuse_dev() {
  awk '$5=="/mnt/user/0/emulated" || $5=="/storage/emulated" {print $3; exit}' \
    "$PROC/self/mountinfo" 2>/dev/null
}
FUSEDEV=$(fuse_dev)
if [ -z "$FUSEDEV" ]; then
  # 开机瞬间 /storage/emulated 可能还没挂好：先等最多 10 秒（1 秒一次），
  # 否则会先误报一次 error=layer_unknown，而层保护又拿不到基准。
  FUSE_WAIT=${SI_FUSE_WAIT:-10}
  case "$FUSE_WAIT" in ''|*[!0-9]*) FUSE_WAIT=10 ;; esac
  # daemon 用 timeout 30 包本脚本：等待必须给 ps/nsenter/mount 留预算。
  [ "$FUSE_WAIT" -gt 10 ] && FUSE_WAIT=10
  if [ "$FUSE_WAIT" -gt 0 ]; then
    say "FUSE 层尚未就绪，等待最多 ${FUSE_WAIT} 秒…"
    i=0
    while [ "$i" -lt "$FUSE_WAIT" ]; do
      sleep 1
      FUSEDEV=$(fuse_dev)
      [ -n "$FUSEDEV" ] && break
      i=$((i + 1))
    done
  fi
fi
if [ -z "$FUSEDEV" ]; then
  # 取不到设备号就分不清"沙箱层"和"共享层"：fail-closed，一条挂载都不动
  say "无法确定本机 FUSE 设备号（层保护不可用），本轮不修改任何挂载"
  echo "RESULT checked=0 broken=0 fixed=0 young=0 error=layer_unknown"
  exit 4
fi

checked=0; broken=0; fixed=0; young=0; skipped=""

while read -r pid age pkg; do
  [ -n "$pid" ] || continue
  [ -d "$PROC/$pid" ] || continue
  mi=$PROC/$pid/mountinfo
  [ -r "$mi" ] || continue

  checked=$((checked + 1))

  if [ "$age" -lt "$AGE_MIN" ]; then young=$((young + 1)); continue; fi

  line=$(grep -m1 -F "|$pkg=" "$ALLOWF" 2>/dev/null)
  [ -n "$line" ] || continue
  line=${line#*|}
  en=${line#*=}; en=${en%%:*}
  allow=${line#*:}
  [ "$en" = "1" ] || { skipped="$skipped disabled"; continue; }
  [ "$VERBOSE" = 1 ] && [ -n "$allow" ] && say "  允许: $pkg -> $allow"

  info=$(awk '
    $4 ~ /^\/(media\/)?[0-9]+\/Android\/data\/.+\/(cache\/)?sdcard$/ && $5 ~ /^\/storage\/emulated\/[0-9]+$/ {
      sb=$4; dv=$3; mp=$5
    }
    $5 ~ /^\/storage\/emulated\/[0-9]+\// { t[$5]=$3; c[$5]++ }
    END {
      if (sb=="") exit
      s=""
      for (k in t) s = s k "=" t[k] "/" c[k] ","
      printf "%s;%s;%s;%s", mp, dv, sb, s
    }' "$mi" 2>/dev/null)
  [ -n "$info" ] || continue

  mp=${info%%;*};  r1=${info#*;}
  fusedev=${r1%%;*}; r2=${r1#*;}
  root=${r2%%;*};  mounts=${r2#*;}
  all=",$mounts"

  # 身份校验：沙箱根里的 /Android/data/<名>/ 必须点名 cmdline 的包名。
  # 已隔离应用 B 可以 exec -a com.victim 伪造 argv[0]，但它继承的沙箱根仍是
  # .../Android/data/<B>/sdcard；root 与 pkg 不一致就绝不做任何 mount。
  rid=${root#*/Android/data/}
  rid=${rid%%/*}
  pkgid=$pkg
  case "$pkgid" in shared-*) pkgid=${pkgid#shared-} ;; esac
  case "$rid" in shared-*) rid=${rid#shared-} ;; esac
  if [ -z "$rid" ] || [ "$rid" != "$pkgid" ]; then
    skipped="$skipped identity"
    say "  跳过 $pkg（沙箱根属于 ${rid:-?}，身份不符）"
    continue
  fi

  # 层保护：沙箱设备号必须等于本机 FUSE 设备号
  if [ -n "$FUSEDEV" ] && [ "$fusedev" != "$FUSEDEV" ]; then
    skipped="$skipped layer"
    say "  跳过 $pkg（沙箱层 $fusedev ≠ FUSE 层 $FUSEDEV）"
    continue
  fi

  case "$root" in
    /media/[0-9]*/Android/data/*)  sb=/data$root ;;
    /[0-9]*/Android/data/*)        sb=/data/media$root ;;
    *) continue ;;
  esac

  # 判定一个目标要不要动：
  #   b = 没有任何挂载（丢挂载现场）→ 直接补
  #   r = 有挂载、但设备号不是本机 FUSE 层或叠了多层 → 拆了重挂
  #   s = 挂载在别的层上（不是本机 FUSE）→ 绝不碰
  target_action() {           # $1=target
    _c=""; _k=0
    case "$all" in *",$1="*) _e=${all#*",$1="}; _c=${_e%%/*}; _k=${_e#*/}; _k=${_k%%,*} ;; esac
    if [ -z "$_k" ] || [ "$_k" = "0" ]; then echo b; return; fi   # 没有挂载：补
    if [ "$_c" = "$fusedev" ] && [ "$_k" = "1" ]; then echo 0; return; fi  # 正好一条、同层：正常
    if [ "$_c" = "$fusedev" ]; then echo r; return; fi              # 同层但叠了/多条：重挂
    echo s                                                          # 别的层：不动
  }

  need=""
  for n in $allow; do
    [ -d "$sb/$n" ] || continue
    a=$(target_action "$mp/$n")
    case "$a" in
      0)   : ;;
      b|r) need="$need $n" ;;
      s)   skipped="$skipped layer"; say "  跳过 $n（挂载在其他层，不动）" ;;
    esac
  done
  # allow 为空也要处理 Android 三连（SI 必建）
  for n in data media obb; do
    t=$mp/Android/$n/$pkg
    [ -d "$sb/Android/$n" ] || continue
    [ -d "/data/media/0/Android/$n/$pkg" ] || continue
    a=$(target_action "$t")
    case "$a" in
      0)   : ;;
      b|r) need="$need Android/$n/$pkg" ;;
      s)   skipped="$skipped layer" ;;
    esac
  done

  [ -n "$need" ] || continue
  broken=$((broken + 1))
  say "修复: $pkg (pid $pid, ${age}s):$need"
  [ "$DRY" = 1 ] && continue

  for n in $need; do
    tgt=$mp/$n
    src=/mnt/user/0/emulated/0/$n

    # 先验源，后拆挂（源不存在、或应用 namespace 里看不到源，都绝不 umount）
    if [ ! -d "$src" ]; then
      skipped="$skipped source"
      say "  跳过 $n（源不存在）"
      continue
    fi
    if ! timeout 2 nsenter -t "$pid" -m -- test -d "$src" </dev/null 2>/dev/null; then
      skipped="$skipped source_ns"
      say "  跳过 $n（应用 namespace 里看不到源）"
      continue
    fi

    j=0
    while [ "$j" -lt 4 ]; do
      set -- $(stat_of "$tgt"); k=${2:-0}
      [ "$k" -gt 0 ] || break
      umount_one "$pid" "$tgt" >/dev/null 2>&1
      j=$((j + 1))
    done
    set -- $(stat_of "$tgt"); k=${2:-0}
    if [ "$k" -gt 0 ]; then
      say "  跳过 $n（umount 未生效）"
      continue
    fi

    err=$(bind_mount "$pid" "$src" "$tgt" 2>&1)
    if [ -n "$err" ]; then
      say "  失败 $n: $err"
      skipped="$skipped bindfail"
      continue
    fi
    set -- $(stat_of "$tgt")
    c=${1:-}; k=${2:-0}
    if [ "$c" = "$fusedev" ] && [ "$k" = "1" ]; then
      fixed=$((fixed + 1))
    else
      say "  校验失败 $n (dev=$c n=$k)，回滚"
      umount_one "$pid" "$tgt" >/dev/null 2>&1
    fi
  done
done < "$CANDF"

say "----"
say "检查 $checked 个已隔离进程，$broken 个需修复，补/重挂 $fixed 条（young=$young）"

# skipped 去重成一个 + 连接的标签
tags=""
for t in $skipped; do
  case " +$tags+" in *"+$t+"*) ;; *) if [ -z "$tags" ]; then tags=$t; else tags="$tags+$t"; fi ;; esac
done
RES="RESULT checked=$checked broken=$broken fixed=$fixed young=$young"
[ -n "$tags" ] && RES="$RES skipped=$tags"
echo "$RES"
exit 0
