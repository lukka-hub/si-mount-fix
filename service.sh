#!/system/bin/sh
case "$0" in */*) MODDIR=${0%/*};; *) MODDIR=.;; esac
DATA=${SI_DATA:-/data/adb/si-mount-fix}
export SI_DATA="$DATA"
export SI_MOD="${SI_MOD:-$MODDIR}"
# 测试钩子不能从宿主机漏进生产守护（SI_PROC 会架空身份/层保护）。
unset SI_TEST SI_PROC SI_TRACE SI_FUSE_WAIT SI_PIPE_BUSY_SLEEP SI_CONF \
      SI_TEST_DATA SI_TEST_SRC SI_TEST_NOW SI_UPTIME \
      SI_BLIND_EVERY SI_BLIND_MIN_HITS SI_BLIND_QUIET \
      SI_FUSE_GRACE SI_FUSE_BACKOFF_MAX SI_FUSE_RETRY
mkdir -p "$DATA" 2>/dev/null

# 用 -s：存在但为空的 config.conf 会让面板显示“配置为空”，必须补默认值。
if [ ! -s "$DATA/config.conf" ]; then
  cat > "$DATA/config.conf" <<'EOF'
ENABLED=1
MODE=auto
POLL_INTERVAL=60
MIN_AGE=15
EOF
fi
chmod 600 "$DATA/config.conf" 2>/dev/null

PROP="$MODDIR/module.prop"
if [ -f "$PROP" ]; then
  desc="已守护 · 启动中 · $(date '+%m-%d %H:%M') ｜存储空间隔离挂载自愈，只补挂载不改配置"
  awk -v d="$desc" 'BEGIN{done=0} /^description=/{print "description=" d; done=1; next} {print} END{if(!done)print "description=" d}' \
    "$PROP" > "$PROP.tmp.$$" 2>/dev/null && mv -f "$PROP.tmp.$$" "$PROP" 2>/dev/null
fi

log -t si-mount-fix "service.sh start"
if command -v setsid >/dev/null 2>&1; then
  setsid sh "$MODDIR/scripts/supervisor.sh" >/dev/null 2>&1 &
else
  nohup sh "$MODDIR/scripts/supervisor.sh" >/dev/null 2>&1 &
fi
i=0; lp=""
while [ "$i" -lt 6 ]; do
  sleep 1
  lp=$(cat "$DATA/.daemon.lock/pid" 2>/dev/null)
  [ -n "$lp" ] && [ -d "/proc/$lp" ] && break
  i=$((i+1))
done
# 守护可能正常地立刻退出（ENABLED=0），用 status.json 的 ts 判断是否刚写过状态，别误判启动失败。
sts=$(sed -n 's/.*"ts":\([0-9]*\).*/\1/p' "$DATA/status.json" 2>/dev/null | head -1)
now=$(date +%s)
fresh=0
if [ -n "$sts" ] && [ "$sts" -ge $((now - 15)) ] 2>/dev/null; then fresh=1; fi
if { [ -z "$lp" ] || [ ! -d "/proc/$lp" ]; } && [ "$fresh" = "0" ]; then
  ts=$(date +%s)
  ver=$(sed -n 's/^version=v//p' "$PROP" 2>/dev/null | head -1)
  [ -n "$ver" ] || ver="?"
  # 兜底状态也要满足面板契约：churn/blind 字段齐全，快照带 config（与守护正常路径一致）
  st="{\"mode\":\"off\",\"reason\":\"launch_failed\",\"reason_text\":\"守护进程启动失败，请查看 daemon.log\",\"pid\":0,\"since\":$ts,\"last_event\":0,\"last_check\":0,\"last_fix\":0,\"last_fixed\":0,\"total_fixed\":0,\"interval\":60,\"min_age\":15,\"procs\":0,\"tracefs\":\"\",\"churn\":0,\"blind\":0,\"blind_since\":0,\"version\":\"$ver\",\"ts\":$ts}"
  printf '%s\n' "$st" > "$DATA/status.json" 2>/dev/null
  if [ -d "$MODDIR/webroot" ]; then
    printf 'window.__SI_SNAPSHOT__={"v":1,"ts":%s,"version":"%s","config":{"enabled":1,"mode":"auto","interval":60,"min_age":15},"status":%s,"log":["守护进程启动失败，请查看 daemon.log"]};\n' \
      "$ts" "$ver" "$st" > "$MODDIR/webroot/snapshot.js.tmp.$$" 2>/dev/null && \
      mv -f "$MODDIR/webroot/snapshot.js.tmp.$$" "$MODDIR/webroot/snapshot.js" 2>/dev/null
  fi
  if [ -f "$PROP" ]; then
    desc="未守护 · 启动失败 · $(date '+%m-%d %H:%M') ｜存储空间隔离挂载自愈，只补挂载不改配置"
    awk -v d="$desc" 'BEGIN{done=0} /^description=/{print "description=" d; done=1; next} {print} END{if(!done)print "description=" d}' \
      "$PROP" > "$PROP.tmp.$$" 2>/dev/null && mv -f "$PROP.tmp.$$" "$PROP" 2>/dev/null
  fi
  log -t si-mount-fix "daemon launch failed"
fi
exit 0
