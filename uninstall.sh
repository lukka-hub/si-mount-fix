#!/system/bin/sh
# 卸载：先停 supervisor 再停 daemon，最后收尾 trace 实例与数据目录。
# 用手工 cmdline 校验代替宽泛的 pkill -f：只杀“shell 解释执行模块脚本”的进程，
# 不会误杀编辑器 / tail / grep 之类只是参数里带文件名的无关进程（同 restart.sh）。

kill_pid() {   # $1=pid
  case "$1" in ''|*[!0-9]*) return 0 ;; esac
  kill -9 "$1" 2>/dev/null
  return 0
}

# $1 = scripts 下的脚本名（如 supervisor.sh）；只匹配 cmdline 里完整的
# ".../scripts/<name>" 或 ".../scripts/<name> <参数>"，且解释器是 sh/mksh
# （允许 timeout 前缀，daemon 调 fix 时是 `timeout 30 sh .../fix-si-mounts.sh`）。
kill_script() {
  _name=$1
  for _d in /proc/[0-9]*; do
    _pid=${_d##*/}
    [ "$_pid" = "$$" ] && continue
    [ -r "$_d/cmdline" ] || continue
    _cmd=$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null) || continue
    [ -n "$_cmd" ] || continue
    # 脚本必须是完整参数：以 /scripts/<name> 结尾或后面跟空格（排除 xxx.sh.bak 等）
    case "$_cmd" in
      */"scripts/$_name"|*/"scripts/$_name "*) ;;
      *) continue ;;
    esac
    # 只处理由 shell 解释器启动的进程
    case "$_cmd" in
      "sh "*|"/system/bin/sh "*|"mksh "*|"busybox sh "*|\
      "timeout "*" sh "*|"timeout "*"/system/bin/sh "*|"timeout "*"mksh "*) ;;
      *) continue ;;
    esac
    kill_pid "$_pid"
  done
  return 0
}

kill_script supervisor.sh
kill_script si-mount-eventd.sh
kill_script fix-si-mounts.sh
sleep 1
kill_script si-mount-eventd.sh

for T in /sys/kernel/tracing /sys/kernel/debug/tracing; do
  [ -d "$T" ] || continue
  if [ -d "$T/instances/si_mount_fix" ]; then
    echo 0 > "$T/instances/si_mount_fix/tracing_on" 2>/dev/null
    echo 0 > "$T/instances/si_mount_fix/events/enable" 2>/dev/null
    rmdir "$T/instances/si_mount_fix" 2>/dev/null
  fi
  for e in si_fix_pu si_fix_pm; do
    echo "-:kprobes/$e" >> "$T/kprobe_events" 2>/dev/null
  done
done

rm -rf /data/adb/si-mount-fix

log -t si-mount-fix "uninstalled"
exit 0
