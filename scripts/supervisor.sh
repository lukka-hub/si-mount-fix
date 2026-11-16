#!/system/bin/sh
# 监督循环：守护退出 30 秒后重启；ENABLED=0 时让守护写 off/disabled 再睡 1 小时。
# 看门狗：status.json 15 分钟没更新就 kill -9，否则会永久占着单实例锁；pid 文件供 restart 定位。
case "$0" in */*) D=${0%/*};; *) D=.;; esac
DATA=${SI_DATA:-/data/adb/si-mount-fix}
echo $$ > "$DATA/.supervisor.pid" 2>/dev/null
_cleanup_pid() {
  if [ "$(cat "$DATA/.supervisor.pid" 2>/dev/null)" = "$$" ]; then
    rm -f "$DATA/.supervisor.pid" 2>/dev/null
  fi
}
trap '_cleanup_pid' EXIT
trap '_cleanup_pid; exit 0' INT TERM HUP

while true; do
  en=$(grep -m 1 -E '^[[:space:]]*ENABLED[[:space:]]*=' "$DATA/config.conf" 2>/dev/null \
       | cut -d= -f2- | sed 's/#.*//' | tr -d ' \r' | tr 'A-Z' 'a-z')
  case "$en" in
    0|false|no|off) en=0 ;;
  esac
  if [ "$en" = "0" ]; then
    sh "$D/si-mount-eventd.sh"          # 只会写一次 off/disabled 然后立刻退出
    sleep 3600
    continue
  fi

  sh "$D/si-mount-eventd.sh" &
  dpid=$!
  while kill -0 "$dpid" 2>/dev/null; do
    sleep 30
    sts=$(sed -n 's/.*"ts":\([0-9]*\).*/\1/p' "$DATA/status.json" 2>/dev/null | head -1)
    now=$(date +%s)
    if [ -n "$sts" ] && [ $((now - sts)) -gt 900 ]; then
      log -t si-mount-fix "watchdog: status ${now-sts}s 未更新，重启守护"
      echo "[$(date '+%m-%d %H:%M:%S')] watchdog: status $((now - sts))s 未更新，重启守护" >> "$DATA/daemon.log" 2>/dev/null
      kill -9 "$dpid" 2>/dev/null
      break
    fi
  done
  wait "$dpid" 2>/dev/null
  sleep 30
done
