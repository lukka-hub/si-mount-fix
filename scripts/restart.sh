#!/system/bin/sh
case "$0" in */*) D=${0%/*};; *) D=.;; esac
# D 是 scripts/，SI_MOD 必须是它的上一级，别指到 scripts 里。
case "$D" in
  */*) MODDIR=${D%/*} ;;
  *)   MODDIR=.. ;;
esac
DATA=${SI_DATA:-/data/adb/si-mount-fix}
export SI_DATA="$DATA"
export SI_MOD="$MODDIR"

SP=$(cat "$DATA/.supervisor.pid" 2>/dev/null)
DP=$(cat "$DATA/.daemon.lock/pid" 2>/dev/null)
sp_ok=0; dp_ok=0
# pid 可能被复用：先核对 cmdline 再杀，避免误杀无关进程。
if [ -n "$SP" ] && [ -d "/proc/$SP" ] \
   && tr '\0' ' ' < "/proc/$SP/cmdline" 2>/dev/null | grep -q 'supervisor\.sh'; then
  kill -9 "$SP" 2>/dev/null; sp_ok=1
fi
if [ -n "$DP" ] && [ -d "/proc/$DP" ] \
   && tr '\0' ' ' < "/proc/$DP/cmdline" 2>/dev/null | grep -q 'si-mount-eventd\.sh'; then
  kill -9 "$DP" 2>/dev/null; dp_ok=1
fi
# pid 文件丢失时只兜底 supervisor/eventd，绝不 pkill fix：在跑的 fix 由 .si-fix.lock 保护，新守护等它结束。
[ "$sp_ok" = 1 ] || pkill -9 -f '^sh .*/supervisor\.sh' 2>/dev/null
[ "$dp_ok" = 1 ] || pkill -9 -f '^sh .*/si-mount-eventd\.sh' 2>/dev/null
rm -rf "$DATA/.daemon.lock" 2>/dev/null   # .si-fix.lock 留着，新进程会按 pid 判活接管
sleep 1
setsid sh "$D/supervisor.sh" >/dev/null 2>&1 &
echo "restarted"
