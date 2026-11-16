#!/system/bin/sh
# list-apps.sh — 只读：列出被隔离的应用、允许的目录、以及当前实际挂载状态
# 输出单行 JSON，供 WebUI 渲染。不做任何挂载/修改操作。
# 状态位：1=已正确挂载  0=允许但没挂上（故障现场）  -1=应用没运行
#
# 性能：配置解析只用 3 个 awk，之后纯 shell 查表；只有"运行中"的应用才读 mountinfo。

CONF=${SI_CONF:-/data/adb/storage-isolation/configuration.json}
DATA=${SI_DATA:-/data/adb/si-mount-fix}
mkdir -p "$DATA" 2>/dev/null

R1=$DATA/.la1.$$; R2=$DATA/.la2.$$; R3=$DATA/.la3.$$
cleanup() { rm -f "$R1" "$R2" "$R3"; }
trap cleanup EXIT

# 1) 模板 id → 目录列表（一次）
grep -o '"mount_dirs_templates":.*' "$CONF" 2>/dev/null \
  | awk '{n=split($0,a,"},{"); for(i=1;i<=n;i++) print a[i]}' \
  | awk '{
      id=""; l="";
      if (match($0, /"id":"[^"]*"/)) id = substr($0, RSTART+6, RLENGTH-7);
      if (match($0, /"list":\[[^]]*\]/)) { l = substr($0, RSTART+8, RLENGTH-9); gsub(/"/,"",l); gsub(/,/," ",l) }
      if (id != "") print "|" id "=" l
    }' > "$R1"
IDMAP=$(tr -d '\n' < "$R1")

# 2) 记录 → pkg;template_ids;custom_dirs（只取 enabled 的）
awk '{
  n = split($0, a, "},{");
  for (i = 1; i <= n; i++) {
    r = a[i];
    if (r !~ /"mount_dirs"/ || r !~ /"enabled":true/) continue;
    pkg=""; t=""; c="";
    if (match(r, /"package_name":"[^"]*"/)) pkg = substr(r, RSTART+16, RLENGTH-17);
    if (match(r, /"template_ids":\[[^]]*\]/)) { t = substr(r, RSTART+16, RLENGTH-17); gsub(/"/,"",t); gsub(/,/," ",t) }
    if (match(r, /"custom_dirs":\[[^]]*\]/))  { c = substr(r, RSTART+15, RLENGTH-16); gsub(/"/,"",c); gsub(/,/," ",c) }
    if (pkg != "") print pkg ";" t ";" c;
  }
}' "$CONF" 2>/dev/null > "$R2"

# 3) 进程名 → pid（同名取第一个）
ps -A -o pid,args 2>/dev/null | awk 'NR>1{ n=split($2,a,":"); print a[1] " " $1 }' > "$R3"

apps=""; total=0; running=0; missing=0

while IFS= read -r line; do
  [ -n "$line" ] || continue
  pkg=${line%%;*}; rest=${line#*;}
  tids=${rest%%;*}; cst=${rest#*;}
  real=${pkg#shared-}

  allow=""
  for t in $tids; do
    v=""
    case "$IDMAP" in
      *"|$t="*) v=${IDMAP#*"|$t="}; v=${v%%|*} ;;
    esac
    if [ -z "$v" ]; then
      case "$t" in
        BUILT_IN_PHOTOS)    v="DCIM Pictures" ;;
        BUILT_IN_MUSIC)     v="Music" ;;
        BUILT_IN_DOWNLOADS) v="Download Documents" ;;
      esac
    fi
    allow="$allow $v"
  done
  allow="$allow $cst"
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
