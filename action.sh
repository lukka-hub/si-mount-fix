#!/system/bin/sh
# Magisk「操作」按钮：展示守护状态并做一次只读体检（不修改挂载）。
case "$0" in */*) D=${0%/*};; *) D=.;; esac
# Magisk action 的 busybox ps 可能顶掉 toybox，固定 PATH 以免误报 error=ps。
PATH=/system/bin:/system/xbin:/product/bin:${PATH:-}
export PATH
DATA=${SI_DATA:-/data/adb/si-mount-fix}
MOD=${SI_MOD:-$D}
mkdir -p "$DATA" 2>/dev/null

VER=$(sed -n 's/^version=v//p' "$MOD/module.prop" 2>/dev/null | head -1)
[ -n "$VER" ] || VER="?"

st=$(cat "$DATA/status.json" 2>/dev/null)
fld() { printf '%s' "$st" | sed -n 's/.*"'"$1"'":\([^,}]*\).*/\1/p' | head -1 | tr -d '"'; }

mode=$(fld mode); reason=$(fld reason); pid=$(fld pid)
since=$(fld since); total=$(fld total_fixed); age_min=$(fld min_age)
interval=$(fld interval); tracefs=$(fld tracefs)
churn=$(fld churn); blind=$(fld blind)

case "$mode" in
  event) mlabel="已守护 · 事件驱动" ;;
  poll)  mlabel="已守护 · 轮询" ;;
  off)   mlabel="未运行（$reason）" ;;
  *)     mlabel="启动中" ;;
esac

case "$reason" in
  ok) rlabel="正常" ;;
  boot)            rlabel="守护启动中，等待初始化" ;;
  tracefs_missing) rlabel="缺少 tracefs，已降级轮询" ;;
  kprobe_failed)   rlabel="kprobe 注册失败，已降级轮询" ;;
  selftest_failed) rlabel="事件自检失败，已降级轮询" ;;
  pipe_busy)       rlabel="事件通道被占用" ;;
  pipe_open_error) rlabel="事件通道打不开（无占用者），已降级轮询" ;;
  pipe_closed)     rlabel="事件通道关闭" ;;
  trace_reset)     rlabel="trace 被重置，已自动恢复" ;;
  forced_poll)     rlabel="已在配置里强制轮询" ;;
  skipped_locked)  rlabel="另一轮修复正在进行，稍后重试" ;;
  blind)           rlabel="事件通道异常（收不到事件），建议重启手机" ;;
  boot_wait)       rlabel="开机等待 FUSE 就绪（自动退避重试）" ;;
  fuse_missing)    rlabel="FUSE 层未就绪（fail-closed，持续重试）" ;;
  disabled)        rlabel="已在配置里停用" ;;
  launch_failed)   rlabel="守护进程启动失败，请查看 daemon.log" ;;
  fix_error_*)     rlabel="修复脚本异常：${reason#fix_error_}" ;;
  *+forced_event_unsupported) rlabel="配置要求事件但环境不支持，已降级轮询" ;;
  *)               rlabel="$reason" ;;
esac

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

if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -d "/proc/$pid" ]; then
  pstate="PID $pid"
else
  pstate="未运行"
  [ "$mode" = "event" ] && pstate="PID $pid（已退出）"
fi

printf '\n 存储空间隔离 · 挂载自愈  v%s\n' "$VER"
printf ' ─────────────────────────────\n'
printf ' 状态   %s\n' "$mlabel"
printf ' 守护   %s · 自 %s 起 · 运行 %s\n' "$pstate" "$since_txt" "$uptxt"
printf ' 状态上报 %s\n' "$rlabel"
printf ' 累计   修复 %s 次\n' "${total:-0}"
if [ "$mode" = "poll" ]; then
  printf ' 配置   轮询 %ss · 最小年龄 %ss\n' "${interval:-?}" "${age_min:-?}"
else
  printf ' 配置   最小年龄 %ss\n' "${age_min:-?}"
fi
printf ' trace  %s\n' "${tracefs:-（不可用）}"
case "$churn" in ''|*[!0-9]*) ;; *) [ "$churn" -gt 0 ] && printf ' 熔断   跳过 %s 个目标（等待期 10 分钟后重试；重试失败锁定至多 1 小时（重启守护/模块也会提前解除））\n' "$churn" ;; esac

raw=$(/system/bin/sh "$MOD/scripts/fix-si-mounts.sh" -n 2>/dev/null | tail -1)
chk=$(printf '%s' "$raw" | sed -n 's/.*checked=\([0-9]*\).*/\1/p')
brk=$(printf '%s' "$raw" | sed -n 's/.*broken=\([0-9]*\).*/\1/p')
fixn=$(printf '%s' "$raw" | sed -n 's/.*fixed=\([0-9]*\).*/\1/p')
yn=$(printf '%s' "$raw" | sed -n 's/.*young=\([0-9]*\).*/\1/p')
skp=$(printf '%s' "$raw" | sed -n 's/.*skipped=\([a-z_+]*\).*/\1/p')
[ -n "$chk" ] || chk=0
[ -n "$brk" ] || brk=0
[ -n "$fixn" ] || fixn=0
printf ' ─────────────────────────────\n'
if printf '%s' "$raw" | grep -q 'defer=fuse'; then
  printf ' 体检   FUSE 未就绪，守护会在开机宽限期内退避重试\n'
elif printf '%s' "$raw" | grep -q 'error='; then
  printf ' 体检   读不到配置或脚本异常（%s）\n' "$(printf '%s' "$raw" | sed -n 's/.*error=//p')"
else
  printf ' 体检   检查 %s 个隔离进程 · %s 个需修复 · 已补 %s 条\n' "$chk" "$brk" "$fixn"
  [ -n "$skp" ] && printf '        跳过：%s\n' "$skp"
  [ -n "$yn" ] && [ "$yn" != "0" ] && printf '        另有 %s 个进程太年轻，稍后会自动补扫\n' "$yn"
fi

recent=$(tail -n 2 "$DATA/daemon.log" 2>/dev/null)
if [ -n "$recent" ]; then
  printf ' ─────────────────────────────\n'
  printf ' 最近\n'
  printf '%s\n' "$recent" | while IFS= read -r l; do
    [ -n "$l" ] && printf '   %s\n' "$l"
  done
fi

if [ "$blind" = 1 ]; then
  printf ' ─────────────────────────────\n'
  printf ' 提示   事件通道异常：请重启手机恢复事件投递（自动重建未启用）\n'
fi
if [ "$reason" = "fuse_missing" ]; then
  printf ' ─────────────────────────────\n'
  printf ' 提示   FUSE 层未就绪：模块保持 fail-closed，不会乱动挂载；持续重试中\n'
fi

if [ "$mode" = "off" ] || [ "$mode" = "starting" ]; then
  printf ' ─────────────────────────────\n'
  printf ' 提示   守护没在运行：重启手机，或在 Magisk 里确认模块已启用\n'
fi

printf '\n 面板：装 KsuWebUI Standalone 后从模块页面打开；没装也能在这里看到状态。\n\n'
exit 0
