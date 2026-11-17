#!/system/bin/sh
# Magisk「操作」按钮：展示守护状态并做一次只读体检（不修改挂载）。
case "$0" in */*) D=${0%/*};; *) D=.;; esac
# Magisk action 的 busybox ps 可能顶掉 toybox，固定 PATH 以免误报 error=ps。
PATH=/system/bin:/system/xbin:/product/bin:${PATH:-}
export PATH
DATA=${SI_DATA:-/data/adb/si-mount-fix}
MOD=${SI_MOD:-$D}
CONF=$DATA/config.conf
mkdir -p "$DATA" 2>/dev/null

VER=$(sed -n 's/^version=v//p' "$MOD/module.prop" 2>/dev/null | head -1)
[ -n "$VER" ] || VER="?"

st=$(cat "$DATA/status.json" 2>/dev/null)
# status.json 是守护写的单行扁平 JSON；一次 awk 取全部字段。
# （字段级 sed 每项 3~4 个 fork，12 个字段在低端机上有可感知的延迟。）
mode=""; reason=""; reason_text=""; pid=""; since=""; total=""
last_fixed=""; age_min=""; interval=""; tracefs=""; churn=""; blind=""
if [ -n "$st" ]; then
  while IFS='=' read -r _k _v; do
    case "$_k" in
      mode) mode=$_v ;;
      reason) reason=$_v ;;
      reason_text) reason_text=$_v ;;
      pid) pid=$_v ;;
      since) since=$_v ;;
      total_fixed) total=$_v ;;
      last_fixed) last_fixed=$_v ;;
      min_age) age_min=$_v ;;
      interval) interval=$_v ;;
      tracefs) tracefs=$_v ;;
      churn) churn=$_v ;;
      blind) blind=$_v ;;
    esac
  done <<EOF
$(printf '%s' "$st" | awk '{
  gsub(/[{}]/, "")
  n = split($0, a, ",")
  for (i = 1; i <= n; i++) {
    p = index(a[i], ":")
    if (p < 2) continue
    k = substr(a[i], 1, p - 1)
    v = substr(a[i], p + 1)
    gsub(/^"|"$/, "", k)
    gsub(/^"|"$/, "", v)
    if (k != "") print k "=" v
  }
}')
EOF
fi
# config.conf 是权威值（fix 脚本自己读 MIN_AGE）；status.json 只做兜底。
# 纯 shell 逐行读，不 fork；值去掉注释、首尾空白和引号，和旧 cfg() 等价。
cfg_age=""; cfg_interval=""; cfg_mode=""; cfg_enabled=""
if [ -f "$CONF" ]; then
  while IFS='=' read -r _k _v; do
    _k=${_k#"${_k%%[![:space:]]*}"}
    _k=${_k%"${_k##*[![:space:]]}"}
    _v=${_v%%#*}
    _v=${_v#"${_v%%[![:space:]]*}"}
    _v=${_v%"${_v##*[![:space:]]}"}
    _v=${_v#\"}
    _v=${_v%\"}
    case "$_k" in
      MIN_AGE) cfg_age=$_v ;;
      POLL_INTERVAL) cfg_interval=$_v ;;
      MODE) cfg_mode=$_v ;;
      ENABLED) cfg_enabled=$_v ;;
    esac
  done < "$CONF"
fi
# fix 的 RESULT skipped=tag+tag；未知 tag 原样显示，不丢信息。
skip_label() {
  case "$1" in
    locked)    echo "另一轮修复进行中" ;;
    disabled)  echo "应用未启用" ;;
    identity)  echo "沙箱身份不符" ;;
    layer)     echo "挂载层级不符" ;;
    source)    echo "源目录不存在" ;;
    source_ns) echo "应用内看不到源" ;;
    bindfail)  echo "绑定挂载失败" ;;
    churn)     echo "频繁被拆已熔断" ;;
    template)  echo "未知模板 id" ;;
    dir_space) echo "目录名无法安全表示" ;;
    dir_invalid) echo "目录路径不合法" ;;
    *)         echo "$1" ;;
  esac
}
# fix 的 RESULT error=token；未知 token 原样显示。
error_label() {
  case "$1" in
    datadir) echo "数据目录不可写" ;;
    config)  echo "配置不可读或格式不对" ;;
    ps)      echo "进程列表读取失败" ;;
    scan)    echo "扫描失败" ;;
    timeout) echo "执行超时" ;;
    exit*)   echo "脚本异常退出（$1）" ;;
    *)       echo "$1" ;;
  esac
}

[ -n "$cfg_age" ] || cfg_age=$age_min
[ -n "$cfg_interval" ] || cfg_interval=$interval

disabled=0
# config.conf 是权威值：用户可能刚把 ENABLED 从 0 改回 1，而 status.json 还是上一次
# 守护退出时写的 disabled；此时不能再按 status 判停用，否则会提示“不需要重启”把用户
# 挡在恢复路径外。没有配置值时才退回 status.reason。
if [ -n "$cfg_enabled" ]; then
  case "$cfg_enabled" in
    0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff]) disabled=1 ;;
  esac
else
  case "$reason" in disabled) disabled=1 ;; esac
fi

# 状态文案：优先用守护写的中文短标签（reason_text，单一词表）；
# 旧版守护没有 reason_text 时用下面的本地词表兜底，保证任何原因都能显示。
if [ -n "$reason_text" ]; then
  rlabel=$reason_text
else
  base=$reason
  suffix=""
  case "$base" in
    *+forced_event_unsupported) base=${base%+forced_event_unsupported}; suffix="；配置要求事件，但环境不支持" ;;
  esac
  case "$base" in
    ok)              rlabel="正常" ;;
    boot)            rlabel="启动中" ;;
    tracefs_missing) rlabel="缺少 tracefs，已降级轮询" ;;
    kprobe_failed)   rlabel="kprobe 注册失败，已降级轮询" ;;
    selftest_failed) rlabel="事件自检失败，已降级轮询" ;;
    pipe_busy)       rlabel="事件通道被占用" ;;
    pipe_open_error) rlabel="事件通道打不开（无占用者），已降级轮询" ;;
    pipe_closed)     rlabel="事件通道关闭" ;;
    trace_reset)     rlabel="trace 被重置，已自动恢复" ;;
    forced_poll)     rlabel="配置要求轮询" ;;
    forced_event_unsupported) rlabel="配置要求事件但环境不支持，已降级轮询" ;;
    skipped_locked)  rlabel="另一轮修复正在进行，稍后重试" ;;
    blind)           rlabel="事件通道异常（收不到事件），建议重启手机" ;;
    boot_wait)       rlabel="开机等待 FUSE 就绪（自动退避重试）" ;;
    fuse_missing)    rlabel="FUSE 层未就绪（fail-closed，持续重试）" ;;
    disabled)        rlabel="已停用" ;;
    launch_failed)   rlabel="守护进程启动失败，请查看 daemon.log" ;;
    fix_error_*)     rlabel="修复脚本异常：${base#fix_error_}" ;;
    '')              rlabel="状态未知" ;;
    *)               rlabel="$base" ;;
  esac
  rlabel="$rlabel$suffix"
fi
# status 还是上一次“已停用”时写的，但 config.conf 已经改回启用：说清楚重启即可恢复，
# 不要按状态文案让用户以为还要再改配置。
if [ "$reason" = "disabled" ] && [ "$disabled" = 0 ]; then
  rlabel="已停用（配置已启用，重启后恢复）"
fi

# 进程是否还活着：status.json 是上一次写的，PID 可能已经退出。
alive=0
if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -d "/proc/$pid" ]; then alive=1; fi

case "$mode" in
  event) if [ "$alive" = 1 ]; then mlabel="已守护 · 事件驱动"; else mlabel="未运行 · $rlabel"; fi ;;
  poll)  if [ "$alive" = 1 ]; then mlabel="已守护 · 轮询"; else mlabel="未运行 · $rlabel"; fi ;;
  off)   mlabel="未运行 · $rlabel" ;;
  '')    mlabel="状态未上报" ;;
  *)     mlabel="启动中" ;;
esac
# 停用是预期状态，不是故障；blind 只在“事件模式 + 进程还在”时才算通道异常。
if [ "$disabled" = 1 ]; then
  if [ "$reason" = "disabled" ]; then
    mlabel="已停用（ENABLED=0）"
  else
    # 配置已停用，但 status 还是停用前的：进程还活着就说“重启后生效”，
    # 已经退出就别说“运行中”（ENABLED=0 时 supervisor 跑一次就睡，进程本来就是死的）。
    if [ "$alive" = 1 ]; then
      mlabel="运行中 · 配置已停用（重启后生效）"
    else
      mlabel="未运行 · 配置已停用"
    fi
  fi
elif [ "$blind" = 1 ] && [ "$mode" = "event" ] && [ "$alive" = 1 ]; then
  mlabel="已守护 · 事件通道异常"
fi

now=$(date +%s)
if [ -n "$since" ] && [ "$since" -gt 0 ] 2>/dev/null; then
  up=$(( now - since ))
  if [ "$up" -lt 0 ]; then up=0; fi
  um=$(( up / 60 )); uh=$(( um / 60 ))
  if [ "$uh" -gt 0 ]; then uptxt="${uh} 小时 $(( um % 60 )) 分"; else uptxt="${um} 分"; fi
  since_txt=$(date -d "@$since" '+%m-%d %H:%M' 2>/dev/null)
  [ -n "$since_txt" ] || since_txt="—"
else
  uptxt="—"; since_txt="—"
fi

if [ "$alive" = 1 ]; then
  pstate="PID $pid"
else
  pstate="未运行"
  case "$mode" in
    event|poll) [ -n "$pid" ] && [ "$pid" != "0" ] && pstate="PID $pid（已退出）" ;;
  esac
fi

printf '\n 存储空间隔离 · 挂载自愈  v%s\n' "$VER"
printf ' ─────────────────────────────\n'
printf ' 状态   %s\n' "$mlabel"
printf ' 状态上报 %s\n' "$rlabel"
printf ' 守护   %s · 自 %s 起 · 运行 %s\n' "$pstate" "$since_txt" "$uptxt"
# total_fixed 是累计成功补上的挂载条数（不是轮次）。
printf ' 本次   修复 %s 条\n' "${last_fixed:-0}"
printf ' 累计   修复 %s 条\n' "${total:-0}"
printf ' 配置   模式 %s · 最小年龄 %ss\n' "${cfg_mode:-auto}" "${cfg_age:-?}"
[ "$mode" = "poll" ] && printf ' 轮询   间隔 %ss\n' "${cfg_interval:-?}"
printf ' trace  %s\n' "${tracefs:-（不可用）}"
case "$churn" in ''|*[!0-9]*) ;; *) [ "$churn" -gt 0 ] && printf ' 熔断   跳过 %s 个目标（等待期 10 分钟后重试；重试失败锁定至多 1 小时（重启守护/模块也会提前解除））\n' "$churn" ;; esac

raw=$(/system/bin/sh "$MOD/scripts/fix-si-mounts.sh" -n 2>/dev/null | tail -1)
chk=$(printf '%s' "$raw" | sed -n 's/.*checked=\([0-9]*\).*/\1/p')
brk=$(printf '%s' "$raw" | sed -n 's/.*broken=\([0-9]*\).*/\1/p')
fixn=$(printf '%s' "$raw" | sed -n 's/.*fixed=\([0-9]*\).*/\1/p')
yn=$(printf '%s' "$raw" | sed -n 's/.*young=\([0-9]*\).*/\1/p')
skp=$(printf '%s' "$raw" | sed -n 's/.*skipped=\([A-Za-z0-9_+.-]*\).*/\1/p')
rchurn=$(printf '%s' "$raw" | sed -n 's/.*churn=\([0-9]*\).*/\1/p')
rretry=$(printf '%s' "$raw" | sed -n 's/.*retry=\([0-9]*\).*/\1/p')
[ -n "$chk" ] || chk=0
[ -n "$brk" ] || brk=0
[ -n "$fixn" ] || fixn=0
[ -n "$rchurn" ] || rchurn=0
[ -n "$rretry" ] || rretry=0
printf ' ─────────────────────────────\n'
if printf '%s' "$raw" | grep -q 'defer=fuse'; then
  printf ' 体检   FUSE 未就绪，本轮未动挂载；守护会在开机宽限期内退避重试\n'
elif printf '%s' "$raw" | grep -q 'error='; then
  _err=$(printf '%s' "$raw" | sed -n 's/.*error=\([A-Za-z0-9_.-]*\).*/\1/p')
  printf ' 体检   执行失败：%s\n' "$(error_label "$_err")"
else
  # 只读体检：这里报的是“需要补”的进程数，不能写成“已补”。
  if [ "$brk" -gt 0 ] 2>/dev/null; then
    printf ' 体检   检查 %s 个隔离进程 · 需修复 %s 个进程（本轮只读，未修改挂载）\n' "$chk" "$brk"
  else
    printf ' 体检   检查 %s 个隔离进程 · 没有需要修复的挂载（本轮只读）\n' "$chk"
  fi
  if [ -n "$skp" ]; then
    # RESULT 契约用 '+' 连接 tag；翻成中文短标签并去重
    _sk=""
    _oldifs=$IFS; IFS='+'
    for _t in $skp; do
      [ -n "$_t" ] || continue
      _l=$(skip_label "$_t")
      case " $_sk " in
        *" $_l "*) ;;
        *) if [ -z "$_sk" ]; then _sk=$_l; else _sk="$_sk、$_l"; fi ;;
      esac
    done
    IFS=$_oldifs
    printf '        跳过：%s\n' "$_sk"
  fi
  [ -n "$yn" ] && [ "$yn" != "0" ] && printf '        另有 %s 个进程太年轻，稍后会自动补扫\n' "$yn"
  [ "$rchurn" -gt 0 ] 2>/dev/null && printf '        熔断：%s 个目标暂时跳过\n' "$rchurn"
  [ "$rretry" -gt 0 ] 2>/dev/null && printf '        约 %s 秒后自动重试\n' "$rretry"
fi

recent=$(tail -n 2 "$DATA/daemon.log" 2>/dev/null)
if [ -n "$recent" ]; then
  printf ' ─────────────────────────────\n'
  printf ' 最近\n'
  printf '%s\n' "$recent" | while IFS= read -r l; do
    [ -n "$l" ] && printf '   %s\n' "$l"
  done
fi

if [ "$blind" = 1 ] && [ "$alive" = 1 ] && [ "$mode" = "event" ]; then
  printf ' ─────────────────────────────\n'
  printf ' 提示   事件通道异常：请重启手机恢复事件投递（自动重建未启用）\n'
fi
if [ "$reason" = "fuse_missing" ]; then
  printf ' ─────────────────────────────\n'
  printf ' 提示   FUSE 层未就绪：模块保持 fail-closed，不会乱动挂载；持续重试中\n'
fi

if [ -z "$st" ]; then
  printf ' ─────────────────────────────\n'
  printf ' 提示   读不到 status.json：守护可能从未启动；重启手机或打开 WebUI 后再看\n'
elif [ "$disabled" = 1 ]; then
  # 停用是用户自己的选择：不提示“重启守护”这种死路；守护还在跑时说明何时生效。
  # 判据用进程存活，而不是 status 的上一轮 reason：ENABLED=0 时守护很快就退出，
  # 旧 status 可能还是 event/ok，此时不能再写“守护仍在运行”。
  if [ "$alive" != 1 ]; then
    printf ' ─────────────────────────────\n'
    printf ' 提示   已在 config.conf 停用（ENABLED=0）：守护不会修复挂载，不需要重启\n'
  else
    printf ' ─────────────────────────────\n'
    printf ' 提示   config.conf 已停用但守护仍在运行：重启守护或重启手机后生效\n'
  fi
else
  notrunning=0
  case "$mode" in
    off|starting|'') notrunning=1 ;;
    event|poll) [ "$alive" = 1 ] || notrunning=1 ;;
  esac
  if [ "$notrunning" = 1 ]; then
    printf ' ─────────────────────────────\n'
    printf ' 提示   守护没在运行：重启手机，或在 Magisk 里确认模块已启用；也可在 WebUI 点「重启守护」\n'
  fi
fi

printf '\n 面板：装 KsuWebUI Standalone 后从模块页面打开；没装也能在这里看到状态。\n\n'
exit 0
