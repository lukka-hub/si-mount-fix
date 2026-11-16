#!/system/bin/sh
# 卸载：先停 supervisor 再停 daemon，最后才 pkill fix；此时无守护会补挂，顺序不能反。
pkill -9 -f '^sh .*/supervisor\.sh' 2>/dev/null
pkill -9 -f '^sh .*/si-mount-eventd\.sh' 2>/dev/null
pkill -9 -f 'fix-si-mounts\.sh' 2>/dev/null
sleep 1
pkill -9 -f '^sh .*/si-mount-eventd\.sh' 2>/dev/null

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
rm -f /data/local/tmp/fix-si-mounts.sh
rm -f /data/local/tmp/.si-recs /data/local/tmp/.si-tpl
rm -rf /data/local/tmp/.si-fix.lock /data/local/tmp/.si-eventd.lock /data/local/tmp/.sitest

log -t si-mount-fix "uninstalled"
