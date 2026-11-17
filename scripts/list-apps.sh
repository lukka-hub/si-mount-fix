#!/system/bin/sh
# list-apps.sh — 只读：列出被隔离的应用、允许的目录、以及当前实际挂载状态
# 输出单行 JSON，供 WebUI 渲染。不做任何挂载/修改操作。
# 状态位：1=已正确挂载  0=允许但没挂上（故障现场）  -1=应用没运行
#
# 性能：配置解析交给 si-config.awk（1 次 awk + 1 次汇总），之后纯 shell 查表；
# 只有"运行中"的应用才读 mountinfo。

CONF=${SI_CONF:-/data/adb/storage-isolation/configuration.json}
DATA=${SI_DATA:-/data/adb/si-mount-fix}
mkdir -p "$DATA" 2>/dev/null

# 配置解析统一走 scripts/si-config.awk（与 fix 共用）；解析失败直接输出可读错误，
# 不让 WebUI 把空数组误当成"没有应用"。
case "$0" in */*) D=${0%/*} ;; *) D=. ;; esac
PARSER=$D/si-config.awk
PARSED=$DATA/.la-parsed.$$
R2=$DATA/.la2.$$; R3=$DATA/.la3.$$
cleanup() { rm -f "$PARSED" "$R2" "$R3"; }
trap cleanup EXIT

if [ ! -r "$PARSER" ]; then
  printf '{"total":0,"running":0,"missing":0,"apps":[],"error":"parser_missing"}'
  exit 2
fi
if ! timeout 20 awk -f "$PARSER" "$CONF" > "$PARSED" 2>/dev/null; then
  printf '{"total":0,"running":0,"missing":0,"apps":[],"error":"config"}'
  exit 2
fi

# 1) 只取启用的 app → "pkg;dir1 dir2"（目录已由解析器校验/去重）
awk -F'|' '
  $1 == "P" {
    if (cur != "") print cur ";" allow
    if ($3 != 1) { cur = ""; allow = ""; next }
    cur = $2; allow = ""
    next
  }
  $1 == "D" { if ($2 == cur) allow = allow (allow == "" ? "" : " ") $3; next }
  END { if (cur != "") print cur ";" allow }
' "$PARSED" > "$R2"

# 3) 进程名 → pid（同名取第一个）
ps -A -o pid,args 2>/dev/null | awk 'NR>1{ n=split($2,a,":"); print a[1] " " $1 }' > "$R3"

apps=""; total=0; running=0; missing=0

while IFS= read -r line; do
  [ -n "$line" ] || continue
  pkg=${line%%;*}; allow=${line#*;}
  real=${pkg#shared-}
  set -- $allow; allow="$*"

  # 注意：不要对长字符串做 case 通配（mksh 在 ~20KB 上是 O(n^2)，单次可达数秒）
  pids=$(grep -F "$real " "$R3" 2>/dev/null | cut -d' ' -f2)
  pid=""
  for _p in $pids; do pid=$_p; break; done

  total=$((total + 1))

  if [ -z "$pid" ]; then
    d=""
    for n in $allow; do d="${d}[\"$n\",-1],"; done
    apps="$apps{\"p\":\"$real\",\"r\":0,\"a\":-1,\"d\":[${d%,}]},"
    continue
  fi

  running=$((running + 1))
  # 同一包有多个进程，取第一个"真的有沙箱挂载"的进程
  info=""
  for pid in $pids; do
    info=$(awk '
      $4 ~ /^\/(media\/)?[0-9]+\/Android\/data\/.+\/(cache\/)?sdcard$/ && $5 ~ /^\/storage\/emulated\/[0-9]+$/ {
        dv=$3; mp=$5
      }
      $5 ~ /^\/storage\/emulated\/[0-9]+\// { t[$5]=$3; c[$5]++ }
      END {
        if (mp=="") exit
        s=""
        for (k in t) s = s k "=" t[k] "/" c[k] ","
        printf "%s;%s;%s", mp, dv, s
      }' "/proc/$pid/mountinfo" 2>/dev/null)
    [ -n "$info" ] && break
  done

  d=""; miss=0; aok=1
  if [ -n "$info" ]; then
    mp=${info%%;*}; r1=${info#*;}
    fusedev=${r1%%;*}; mounts=${r1#*;}
    [ "$mounts" = "$r1" ] && mounts=""
    all=",$mounts"
    for n in $allow; do
      t=$mp/$n; c=""; k=0
      case "$all" in *",$t="*) e=${all#*",$t="}; c=${e%%/*}; k=${e#*/}; k=${k%%,*} ;; esac
      if [ "$c" = "$fusedev" ] && [ "$k" = "1" ]; then s=1; else s=0; miss=$((miss+1)); fi
      d="${d}[\"$n\",$s],"
    done
    anysrc=0
    for n in data media obb; do
      [ -d "/data/media/0/Android/$n/$real" ] || continue
      anysrc=1
      t=$mp/Android/$n/$real; c=""; k=0
      case "$all" in *",$t="*) e=${all#*",$t="}; c=${e%%/*}; k=${e#*/}; k=${k%%,*} ;; esac
      [ "$c" = "$fusedev" ] && [ "$k" = "1" ] || aok=0
    done
    [ "$anysrc" = 0 ] && aok=-2
  else
    aok=-1
    for n in $allow; do d="${d}[\"$n\",-1],"; done
  fi

  [ "$miss" -gt 0 ] && missing=$((missing + 1))
  apps="$apps{\"p\":\"$real\",\"r\":1,\"a\":$aok,\"d\":[${d%,}]},"
done < "$R2"

printf '{"total":%d,"running":%d,"missing":%d,"apps":[%s]}' \
  "$total" "$running" "$missing" "${apps%,}"
