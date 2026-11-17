#!/system/bin/sh
# 双模守护：优先 kprobe 事件；tracefs 受 SELinux/权限限制时降级轮询，不改系统 trace 配置。
# read 退出码必须紧跟 read 取（否则超时被误判为通道关闭）；事件去抖后统一修一次，不丢事件。

DATA=${SI_DATA:-/data/adb/si-mount-fix}
MOD=${SI_MOD:-/data/adb/modules/si-mount-fix}
CFG=$DATA/config.conf
STATUS=$DATA/status.json
LOG=$DATA/daemon.log
FIX=$MOD/scripts/fix-si-mounts.sh
SNAP=$MOD/webroot/snapshot.js
PROP=$MOD/module.prop
INST_NAME=si_mount_fix
HEALTH=300          # 空闲健康检查间隔（秒）
VERSION=$(timeout -k 1 5 sed -n 's/^version=v//p' "$MOD/module.prop" 2>/dev/null | head -1)
[ -n "$VERSION" ] || VERSION="?"

mkdir -p "$DATA" 2>/dev/null
export SI_DATA="$DATA"
exec 0</dev/null

log() {
  if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
    mv -f "$LOG" "$LOG.1" 2>/dev/null
  fi
  echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"
}

dbg() { [ "$SI_DEBUG" = 1 ] && log "step: $*"; }

mono() {
  # 纯 shell 读 /proc/uptime，避免每次 read -t 都 fork；不可读时退回 epoch 秒。
  _up=""
  if [ -r /proc/uptime ]; then
    read -r _up _ < /proc/uptime 2>/dev/null
  fi
  if [ -n "$_up" ]; then
    echo "${_up%%.*}"
  else
    date +%s
  fi
}
now_s() { date +%s; }
# mksh 的算术是 32 位：1700000000000 这类毫秒值不能直接相减/比较。
# 只做“最近 1 秒”判断，交给 awk 的 double，既避免溢出也保持事件循环可读。
ms_recent() {   # $1=last_ms $2=now_ms
  case "${1:-}${2:-}" in ''|*[!0-9]*) return 1 ;; esac
  awk -v a="$2" -v b="$1" 'BEGIN { exit !(b > 0 && a - b < 1000) }'
}
uptime_s() {
  _u=""
  if [ "$SI_TEST" = 1 ] && [ -n "$SI_UPTIME" ]; then
    _u=$SI_UPTIME
  elif [ -r /proc/uptime ]; then
    read -r _u _ < /proc/uptime 2>/dev/null
  fi
  _u=${_u%%.*}
  case "$_u" in
    ''|*[!0-9]*) _u=$(( $(now_s) - SINCE )) ;;
  esac
  [ "$_u" -lt 0 ] && _u=0
  echo "$_u"
}

# trace_pipe 只允许一个读者；open 失败也可能是 EACCES/ELOOP/EISDIR 等坏实例。
# 先试打开，失败后扫 /proc/*/fd：有活持有者才按 busy 处理，否则按 open_error 降级轮询。
pipe_open_ok() {   # $1=trace_pipe 路径
  [ -e "$1" ] || [ -L "$1" ] || return 1
  [ -d "$1" ] && return 1      # 实例损坏成目录（EISDIR）：不是可读 pipe
  # timeout -k 兜底 FIFO/异常文件：open 本身可能阻塞，超时连子进程一起杀。
  timeout -k 1 2 sh -c ': < "$1"' _ "$1" 2>/dev/null
}

pipe_has_holder() {   # $1=trace_pipe 路径；0=有活持有者，1=确认没有，2=扫描超时/未知
  # 单次 ls 落文件再 grep，避免逐 fd readlink（真机 500+ 进程会卡几分钟）；
  # 超时返回 2（未知）由调用方按 busy 处理，绝不重建实例。
  _hf=$DATA/.pipe-fds.$$
  timeout -k 1 2 ls -l /proc/[0-9]*/fd > "$_hf" 2>/dev/null
  _rc=$?
  if [ "$_rc" -eq 124 ] || [ "$_rc" -eq 137 ]; then
    rm -f "$_hf" 2>/dev/null
    return 2
  fi
  # 精确匹配“fd 指向本次实例的 trace_pipe”，不要按后缀猜：别的 trace 根（测试/旧实例）
  # 下同名实例的 fd 也会包含 "/instances/<name>/trace_pipe"，按后缀匹配会误判成“被占用”。
  if grep -F " -> $1" "$_hf" 2>/dev/null | grep -q -v " /proc/$$/fd/" 2>/dev/null; then
    rm -f "$_hf" 2>/dev/null
    return 0
  fi
  rm -f "$_hf" 2>/dev/null
  return 1
}

cfg_get() {
  grep -m 1 -E "^[[:space:]]*$1[[:space:]]*=" "$CFG" 2>/dev/null | cut -d= -f2- | sed 's/#.*//' | tr -d ' \r'
}

ENABLED=$(cfg_get ENABLED);              [ -n "$ENABLED" ] || ENABLED=1
CFG_MODE=$(cfg_get MODE);                [ -n "$CFG_MODE" ] || CFG_MODE=auto
POLL_INTERVAL=$(cfg_get POLL_INTERVAL);  [ -n "$POLL_INTERVAL" ] || POLL_INTERVAL=60
MIN_AGE=$(cfg_get MIN_AGE);              [ -n "$MIN_AGE" ] || MIN_AGE=15
case "$CFG_MODE" in auto|event|poll) ;; *) CFG_MODE=auto ;; esac
case "$POLL_INTERVAL" in ''|*[!0-9]*) POLL_INTERVAL=60 ;; esac
[ "$POLL_INTERVAL" -lt 10 ] && POLL_INTERVAL=10
[ "$POLL_INTERVAL" -gt 600 ] && POLL_INTERVAL=600
case "$MIN_AGE" in ''|*[!0-9]*) MIN_AGE=15 ;; esac
[ "$MIN_AGE" -lt 5 ] && MIN_AGE=5
[ "$MIN_AGE" -gt 120 ] && MIN_AGE=120
# 与 supervisor.sh / WebUI 保持一致：只有显式 0/false/no/off 算停用（大小写不敏感），
# 其它非空值按启用处理；否则三端对 "True"/未知写法判断不同，会出现反复起停。
case "$(printf '%s' "$ENABLED" | tr 'A-Z' 'a-z')" in
  0|false|no|off) ENABLED=0 ;;
  *) ENABLED=1 ;;
esac
export SI_MIN_AGE=$MIN_AGE
dbg "config parsed mode=$CFG_MODE interval=$POLL_INTERVAL"

PIPE_PROBE_EVERY=$POLL_INTERVAL
[ "$PIPE_PROBE_EVERY" -gt 60 ] && PIPE_PROBE_EVERY=60
[ "$PIPE_PROBE_EVERY" -lt 1 ] && PIPE_PROBE_EVERY=1
# 自测缝：pipe 降级期间的重探周期。默认跟随 POLL_INTERVAL，pipebusy 测试要把它
# 压到 1 秒，否则“释放 holder → 重探 → 退出”只能在 10 秒量级的窗口里等。
if [ "$SI_TEST" = 1 ]; then
  case "$SI_PIPE_PROBE_EVERY" in ''|*[!0-9]*) ;; *) PIPE_PROBE_EVERY=$SI_PIPE_PROBE_EVERY ;; esac
fi
[ "$PIPE_PROBE_EVERY" -lt 1 ] && PIPE_PROBE_EVERY=1

SINCE=$(now_s)
TOTAL=$(cat "$DATA/.total" 2>/dev/null); case "$TOTAL" in ''|*[!0-9]*) TOTAL=0 ;; esac
TOTAL_SANDBOX=$(cat "$DATA/.total_sandbox" 2>/dev/null); case "$TOTAL_SANDBOX" in ''|*[!0-9]*) TOTAL_SANDBOX=0 ;; esac
MODE=starting; LAST_EVENT=0; LAST_FIX=0; LAST_FIXED=0; LAST_CHECK=0; PROCS=0; TRACEFS=""
INST=""
PIPE_DEGRADED=0     # 1=trace_pipe 被占/打不开，轮询期间定期重探
PIPE_REASON=""      # 降级原因，run_fix 后恢复，避免 status 被洗成 ok
RETRY_AT=0
LAST_RUN=0
LAST_MODE_FILE=$DATA/.last_mode
FIX_ERR_LOGGED=""
PUB_KEY=""; PUB_AT=0
CHURN=0; BLIND=0; BLIND_SINCE=0
LAST_SANDBOX=0; SAND_GONE=0; SAND_STALE=0; SAND_ROLLBACK=0; SAND_SKIP=0; SAND_REPORT_LAST=""
LAST_FIX_MS=0
DEFER_COUNT=0; FUSE_GRACE=180; FUSE_BACKOFF_MAX=30; FUSE_RETRY=60
EVENT_RETRY_AT=0          # kprobe/selftest 失败后，多久再尝试切回事件模式（秒）
POLL_REASON=""           # 轮询降级原因；run_fix 成功时不能把它洗成 ok
FUSE_MISSING_LOGGED=0
BLIND_EVERY=60            # 假活采样周期（秒）
BLIND_MIN_HITS=20         # 一个周期内 kprobe 至少命中多少次才判定
BLIND_QUIET=120           # last_event 至少旧于 2 个周期
BLIND_HITS=0; BLIND_A=0; BLIND_B=0; BLIND_HAVE=0
NEXT_BLIND=0; NEXT_SCAN=0
if [ "$SI_TEST" = 1 ]; then
  case "$SI_BLIND_EVERY" in ''|*[!0-9]*) ;; *) BLIND_EVERY=$SI_BLIND_EVERY ;; esac
  case "$SI_BLIND_MIN_HITS" in ''|*[!0-9]*) ;; *) BLIND_MIN_HITS=$SI_BLIND_MIN_HITS ;; esac
  case "$SI_BLIND_QUIET" in ''|*[!0-9]*) ;; *) BLIND_QUIET=$SI_BLIND_QUIET ;; esac
fi
[ "$BLIND_EVERY" -lt 1 ] && BLIND_EVERY=1
[ "$BLIND_MIN_HITS" -lt 1 ] && BLIND_MIN_HITS=1
[ "$BLIND_QUIET" -lt 0 ] && BLIND_QUIET=0
if [ "$SI_TEST" = 1 ]; then
  case "$SI_FUSE_GRACE" in ''|*[!0-9]*) ;; *) FUSE_GRACE=$SI_FUSE_GRACE ;; esac
  case "$SI_FUSE_BACKOFF_MAX" in ''|*[!0-9]*) ;; *) FUSE_BACKOFF_MAX=$SI_FUSE_BACKOFF_MAX ;; esac
  case "$SI_FUSE_RETRY" in ''|*[!0-9]*) ;; *) FUSE_RETRY=$SI_FUSE_RETRY ;; esac
fi
[ "$FUSE_GRACE" -lt 1 ] && FUSE_GRACE=1
[ "$FUSE_BACKOFF_MAX" -lt 1 ] && FUSE_BACKOFF_MAX=1
[ "$FUSE_RETRY" -lt 1 ] && FUSE_RETRY=1

# 状态文案的唯一定义处：status.json 的 reason_text 由这里生成，action/WebUI 直接展示，
# 不再各自维护一份 case（两边已经漂移过一次）。
reason_label() {
  _rl_base=$REASON
  _rl_suf=""
  case "$_rl_base" in
    *+forced_event_unsupported)
      _rl_base=${_rl_base%+forced_event_unsupported}
      _rl_suf="；配置要求事件，但环境不支持"
      ;;
  esac
  _rl_txt=$(_reason_base "$_rl_base")
  printf '%s%s\n' "$_rl_txt" "$_rl_suf"
}

_reason_base() {
  case "$1" in
    ok)               echo "正常" ;;
    boot)             echo "启动中" ;;
    disabled)         echo "已停用" ;;
    tracefs_missing)  echo "缺少 tracefs，已降级轮询" ;;
    kprobe_failed)    echo "kprobe 注册失败，已降级轮询" ;;
    selftest_failed)  echo "事件自检失败，已降级轮询" ;;
    pipe_busy)        echo "事件通道被占用" ;;
    pipe_open_error)  echo "事件通道打不开（无占用者），已降级轮询" ;;
    pipe_closed)      echo "事件通道关闭" ;;
    trace_reset)      echo "trace 被重置，已自动恢复" ;;
    forced_poll)      echo "配置要求轮询" ;;
    skipped_locked)   echo "另一轮修复正在进行，稍后重试" ;;
    blind)            echo "事件通道异常（收不到事件），建议重启手机" ;;
    boot_wait)        echo "开机等待 FUSE 就绪（自动退避重试）" ;;
    fuse_missing)     echo "FUSE 层未就绪（fail-closed，持续重试）" ;;
    launch_failed)    echo "守护进程启动失败，请查看 daemon.log" ;;
    fix_error_*)      echo "修复脚本异常：${1#fix_error_}" ;;
    *)                echo "$1" ;;
  esac
}

write_status() {
  tmp="$STATUS.$$.tmp"
  cat > "$tmp" <<EOF
{"mode":"$MODE","reason":"$REASON","reason_text":"$(reason_label)","pid":$$,"since":$SINCE,"last_event":$LAST_EVENT,"last_check":$LAST_CHECK,"last_fix":$LAST_FIX,"last_fixed":$LAST_FIXED,"total_fixed":$TOTAL,"interval":$POLL_INTERVAL,"min_age":$MIN_AGE,"procs":$PROCS,"tracefs":"$TRACEFS","churn":$CHURN,"sandbox":$LAST_SANDBOX,"last_sandbox":$LAST_SANDBOX,"total_sandbox":$TOTAL_SANDBOX,"sandbox_gone":$SAND_GONE,"sandbox_stale":$SAND_STALE,"sandbox_rollback":$SAND_ROLLBACK,"sandbox_skip":$SAND_SKIP,"blind":$BLIND,"blind_since":$BLIND_SINCE,"version":"$VERSION","ts":$(now_s)}
EOF
  mv -f "$tmp" "$STATUS" 2>/dev/null
  old=$(cat "$LAST_MODE_FILE" 2>/dev/null)
  if [ "$old" != "$MODE/$REASON" ]; then
    echo "$MODE/$REASON" > "$LAST_MODE_FILE"
    log "mode=$MODE reason=$REASON tracefs=$TRACEFS"
  fi
}

prop_desc() {
  case "$MODE" in
    event)
      case "$REASON" in
        boot_wait)     echo "已守护 · 等待 FUSE 就绪" ;;
        fuse_missing)  echo "已守护 · FUSE 层未就绪" ;;
        *)
          if [ "$BLIND" = 1 ]; then
            echo "已守护 · 事件通道异常，请重启手机"
          else
            echo "已守护 · 事件驱动"
          fi ;;
      esac ;;
    poll)
      case "$REASON" in
        boot_wait)    echo "已守护 · 等待 FUSE 就绪" ;;
        fuse_missing) echo "已守护 · FUSE 层未就绪" ;;
        *)            echo "已守护 · 轮询 ${POLL_INTERVAL}s" ;;
      esac ;;
    off)
      case "$REASON" in
        disabled)      echo "已停止 · 已停用" ;;
        launch_failed) echo "已停止 · 启动失败" ;;
        pipe_closed)   echo "已停止 · 事件通道关闭" ;;
        *)             echo "已停止 · $REASON" ;;
      esac ;;
    *) echo "启动中" ;;
  esac
}

write_prop() {
  [ -f "$PROP" ] || return 0
  d="$(prop_desc)"
  [ "$TOTAL" -gt 0 ] && d="$d · 累计修复 $TOTAL 条"
  dom=$(date '+%m-%d %H:%M')
  desc="$d · $dom ｜存储空间隔离挂载自愈，只补挂载不改配置"
  cur=$(timeout -k 1 5 grep -m1 '^description=' "$PROP" 2>/dev/null)
  [ "$cur" = "description=$desc" ] && return 0
  timeout -k 1 5 awk -v d="$desc" 'BEGIN{done=0} /^description=/{print "description=" d; done=1; next} {print} END{if(!done)print "description=" d}' \
    "$PROP" > "$PROP.tmp.$$" 2>/dev/null && mv -f "$PROP.tmp.$$" "$PROP" 2>/dev/null
}

publish() {                     # $1=force
  now=$(now_s)
  key="$MODE|$REASON|$TOTAL|$PROCS|$CHURN|$BLIND|$$"
  if [ "$1" != "force" ] && [ "$key" = "$PUB_KEY" ] && [ $((now - PUB_AT)) -lt 180 ]; then
    return 0
  fi
  if [ -d "$MOD/webroot" ]; then
    st=$(cat "$STATUS" 2>/dev/null)
    [ -n "$st" ] || st=null
    cfg="{\"enabled\":$ENABLED,\"mode\":\"$CFG_MODE\",\"interval\":$POLL_INTERVAL,\"min_age\":$MIN_AGE}"
    lines=$(timeout -k 1 5 tail -n 12 "$LOG" 2>/dev/null \
      | timeout -k 1 5 sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/[[:cntrl:]]/ /g' \
      | timeout -k 1 5 awk '{printf "%s\"%s\"", (n++?",":""), $0}')
    tmp="$SNAP.$$"
    printf 'window.__SI_SNAPSHOT__={"v":1,"ts":%s,"version":"%s","config":%s,"status":%s,"log":[%s]};\n' \
      "$now" "$VERSION" "$cfg" "$st" "$lines" > "$tmp" 2>/dev/null && mv -f "$tmp" "$SNAP" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
  fi
  if [ "$1" = "force" ] || [ "$key" != "$PUB_KEY" ]; then
    write_prop
  fi
  PUB_KEY=$key; PUB_AT=$now
}

health() {
  # 只有事件模式才保活 trace 实例；轮询模式已主动关掉 events/tracing_on，再打开就是空转。
  [ "$MODE" = "event" ] || return 0
  [ -n "$INST" ] && [ -d "$INST" ] || return 0
  if [ "$(cat "$INST/tracing_on" 2>/dev/null)" != "1" ]; then
    echo 1 > "$INST/tracing_on" 2>/dev/null
    if [ "$BLIND" = 1 ]; then REASON=blind; else REASON=trace_reset; fi
    write_status
    publish
    log "tracing_on 被关闭，已重新打开"
  fi
  for e in si_fix_pu si_fix_pm; do
    [ "$(cat "$INST/events/kprobes/$e/enable" 2>/dev/null)" = "1" ] || \
      echo 1 > "$INST/events/kprobes/$e/enable" 2>/dev/null
  done
}

# 假活自检：三信号（kprobe 命中、实例 read events、last_event 年龄）连续 2 个采样周期
# 命中才判定。§3 前置实验未做，重建读端不可证可靠，故只写 blind 提示重启，不删实例/kprobe。
sample_blind() {
  [ "$MODE" = "event" ] || return 0
  [ "$REASON" = "boot_wait" ] && return 0
  [ "$REASON" = "fuse_missing" ] && return 0
  [ -n "$INST" ] && [ -d "$INST" ] || return 0
  [ -r "$TRACEFS/kprobe_profile" ] || return 0
  set -- "$INST"/per_cpu/cpu*/stats
  [ -f "$1" ] || return 0
  a=$(awk '$1=="si_fix_pu" || $1=="si_fix_pm" {s+=$2} END {print s+0}' "$TRACEFS/kprobe_profile" 2>/dev/null)
  b=$(awk '$1=="read" && $2=="events:" {s+=$3} END {print s+0}' "$@" 2>/dev/null)
  case "$a$b" in ''|*[!0-9]*) return 0 ;; esac

  now=$(now_s)
  if [ "$BLIND_HAVE" = 1 ]; then
    da=$((a - BLIND_A)); db=$((b - BLIND_B))
    if [ "$da" -lt 0 ] || [ "$db" -lt 0 ]; then
      # 计数器被重建/清零：只重设基线，本轮不下结论。
      BLIND_HAVE=0; BLIND_HITS=0
    else
      if [ "$da" -ge "$BLIND_MIN_HITS" ] && [ $((db * 4)) -le "$da" ] \
         && [ $((now - LAST_EVENT)) -ge "$BLIND_QUIET" ]; then
        BLIND_HITS=$((BLIND_HITS + 1))
      else
        BLIND_HITS=0
        # 只有正向信号才清 blind；这一分钟没人拆挂载（da/db 都为 0）不算恢复。
        if [ "$BLIND" = 1 ] && [ "$db" -gt 0 ]; then
          BLIND=0; BLIND_SINCE=0; REASON=ok
          log "事件通道恢复：kprobe +$da / read +$db / last_event $((now - LAST_EVENT))s 前"
          write_status; publish force
        fi
      fi
      if [ "$BLIND_HITS" -ge 2 ] && [ "$BLIND" != 1 ]; then
        BLIND=1; BLIND_SINCE=$now; REASON=blind
        log "事件通道假活：kprobe +$da，read events +$db，last_event 已 $((now - LAST_EVENT))s；不自动重建，请重启手机"
        write_status; publish force
      fi
    fi
  fi
  BLIND_A=$a; BLIND_B=$b; BLIND_HAVE=1
}

run_fix() {
  now=$(now_s)
  # 事件密集（装包/启动风暴）时最多 2 秒扫一次，避免重复整表扫描。
  if [ "$LAST_RUN" -gt 0 ] && [ $((now - LAST_RUN)) -lt 2 ]; then
    # defer/wait 的退避由 RETRY_AT 驱动，不能被 2 秒门改短；这类扫描本身很便宜。
    case "$REASON" in
      boot_wait|fuse_missing) ;;
      *) RETRY_AT=$(( $(mono) + 2 )); return 0 ;;
    esac
  fi
  LAST_RUN=$now
  health
  out=$(timeout 30 sh "$FIX" -q 2>&1 3<&-); rc=$?
  fixed=$(echo "$out"   | sed -n 's/.*fixed=\([0-9]*\).*/\1/p' | tail -1)
  checked=$(echo "$out" | sed -n 's/.*checked=\([0-9]*\).*/\1/p' | tail -1)
  broken=$(echo "$out"  | sed -n 's/.*broken=\([0-9]*\).*/\1/p' | tail -1)
  young=$(echo "$out"   | sed -n 's/.*young=\([0-9]*\).*/\1/p' | tail -1)
  ferr=$(echo "$out"    | sed -n 's/.*error=\([A-Za-z0-9_+.-]*\).*/\1/p' | tail -1)
  skip=$(echo "$out"    | sed -n 's/.*skipped=\([A-Za-z0-9_+.-]*\).*/\1/p' | tail -1)
  churn=$(echo "$out"   | sed -n 's/.*churn=\([0-9]*\).*/\1/p' | tail -1)
  retry=$(echo "$out"   | sed -n 's/.*retry=\([0-9]*\).*/\1/p' | tail -1)
  sbx=$(echo "$out"     | sed -n 's/.*sandbox=\([0-9]*\).*/\1/p' | tail -1)
  defer=$(echo "$out"   | sed -n 's/.*defer=\([A-Za-z0-9_+.-]*\).*/\1/p' | tail -1)
  [ -n "$fixed" ] || fixed=0
  case "$churn" in ''|*[!0-9]*) churn=0 ;; esac
  case "$retry" in ''|*[!0-9]*) retry=0 ;; esac
  case "$sbx" in ''|*[!0-9]*) sbx=0 ;; esac

  # FUSE 未就绪不是错误：宽限期内只写 boot_wait，宽限后才报 fuse_missing（仍 fail-closed）。
  if [ "$defer" = "fuse" ]; then
    DEFER_COUNT=$((DEFER_COUNT + 1))
    _up=$(uptime_s)
    if [ "$_up" -lt "$FUSE_GRACE" ]; then
      REASON=boot_wait
      case "$DEFER_COUNT" in
        1) _bo=1 ;; 2) _bo=2 ;; 3) _bo=4 ;; 4) _bo=8 ;; 5) _bo=15 ;; *) _bo=30 ;;
      esac
      [ "$_bo" -gt "$FUSE_BACKOFF_MAX" ] && _bo=$FUSE_BACKOFF_MAX
      RETRY_AT=$(( $(mono) + _bo ))
      write_status
      publish
      return 0
    fi
    REASON=fuse_missing
    LAST_FIX=$(now_s)
    if [ "$FUSE_MISSING_LOGGED" != 1 ]; then
      FUSE_MISSING_LOGGED=1
      log "FUSE 层 ${_up}s 未就绪（fail-closed，继续每 60s 重试）"
    fi
    RETRY_AT=$(( $(mono) + FUSE_RETRY ))
    write_status
    publish
    return 0
  fi

  printf '%s\n' "$out" | while IFS='|' read -r ntag np nt ns nu; do
    [ "$ntag" = "N" ] || continue
    case "$ns" in
      wait)  log "熔断 $np -> $nt（10 分钟后重试，until=$nu）" ;;
      block) log "熔断 $np -> $nt：重试仍失败，1 小时内不再自动修复" ;;
    esac
  done

  if [ "$rc" -eq 124 ]; then ferr=timeout; fi
  if [ "$rc" -ne 0 ] && [ -z "$ferr" ]; then ferr="exit$rc"; fi

  # 只有抢锁才代表这轮没跑；disabled/layer/source 是正常的单应用跳过。
  skip_locked=0
  case "+$skip+" in *"+locked"*) skip_locked=1 ;; esac

  if [ "$skip_locked" = 1 ]; then
    # 抢锁：不算检查过，2 秒后再试；restart 不杀正在跑的 fix（由 .si-fix.lock 保护）。
    LAST_FIX=$(now_s)
    REASON="skipped_locked"
    RETRY_AT=$(( $(mono) + 2 ))
  elif [ -n "$ferr" ]; then
    LAST_FIX=$(now_s)
    REASON="fix_error_$ferr"
    if [ "$FIX_ERR_LOGGED" != "$ferr" ]; then
      FIX_ERR_LOGGED=$ferr
      log "修复脚本异常 error=$ferr（原始输出：$(echo "$out" | tail -1)）"
    fi
  else
    FIX_ERR_LOGGED=""
    [ -n "$checked" ] && PROCS=$checked
    LAST_CHECK=$(now_s)
    LAST_FIX=$LAST_CHECK
    REASON=ok
    CHURN=$churn
    # “本次修复”只代表当前这一轮：成功扫描后按本轮 fixed 覆盖，fixed=0 也要归零。
    LAST_FIXED=$fixed
    if [ "$DEFER_COUNT" -gt 0 ] || [ "$FUSE_MISSING_LOGGED" = 1 ]; then
      log "FUSE 层已就绪，恢复扫描"
    fi
    DEFER_COUNT=0
    FUSE_MISSING_LOGGED=0
    if [ "$fixed" -gt 0 ]; then
      TOTAL=$((TOTAL + fixed))
      echo "$TOTAL" > "$DATA/.total" 2>/dev/null
      log "修复 $fixed 条（broken=$broken, checked=$checked）"
      # 刚修过：下一个事件立即允许再扫，让 <1 秒的 churn 判据可达。
      LAST_RUN=0
      LAST_FIX_MS=$(date +%s%3N 2>/dev/null)
      case "$LAST_FIX_MS" in ''|*[!0-9]*) LAST_FIX_MS=0 ;; esac
    fi
    LAST_SANDBOX=$sbx
    case "+$skip+" in *"+sandbox_gone"*) SAND_GONE=1 ;; *) SAND_GONE=0 ;; esac
    case "+$skip+" in *"+sandbox_stale"*) SAND_STALE=1 ;; *) SAND_STALE=0 ;; esac
    case "+$skip+" in *"+rollback"*) SAND_ROLLBACK=1 ;; *) SAND_ROLLBACK=0 ;; esac
    case "+$skip+" in *"+sandbox_skip"*) SAND_SKIP=1 ;; *) SAND_SKIP=0 ;; esac
    if [ "$sbx" -gt 0 ]; then
      TOTAL_SANDBOX=$((TOTAL_SANDBOX + sbx))
      echo "$TOTAL_SANDBOX" > "$DATA/.total_sandbox" 2>/dev/null
    fi
    # 沙箱报告文件只列“变化过”的包，避免每轮刷日志。
    _srep=$(cat "$DATA/.sandbox_report" 2>/dev/null)
    if [ -z "$_srep" ]; then
      SAND_REPORT_LAST=""
    elif [ "$_srep" != "$SAND_REPORT_LAST" ]; then
      # 用 here-doc 让 while 在当前 shell 跑：赋值不能被管道子 shell 吞掉，
      # 否则 SAND_REPORT_LAST 永远是空，同一份报告会每轮重复记日志。
      while IFS=' ' read -r _skind _spkg; do
        [ -n "$_spkg" ] || continue
        case "$_skind" in
          rebuilt) log "沙箱重建: $_spkg" ;;
          gone)    log "沙箱丢失: $_spkg（下一轮重试）" ;;
          stale)   log "沙箱僵死: $_spkg（需重启应用）" ;;
          skip)    log "沙箱未重建: $_spkg（安全拒绝，需重启应用）" ;;
        esac
      done <<EOF
$_srep
EOF
      SAND_REPORT_LAST=$_srep
    fi
  fi

  case "$young" in ''|*[!0-9]*) young=0 ;; esac
  if [ "$young" -gt 0 ]; then
    RETRY_AT=$(( $(mono) + MIN_AGE + 2 ))
  fi
  # 熔断重试复用现有 RETRY_AT + read -t，不新增定时器。
  if [ "$retry" -gt 0 ]; then
    _rt=$(( $(mono) + retry ))
    if [ "$RETRY_AT" -eq 0 ] || [ "$_rt" -lt "$RETRY_AT" ]; then
      RETRY_AT=$_rt
    fi
  fi
  # 降级轮询期间 run_fix 不能把原因洗成 ok，否则 status 会掩盖 pipe/事件降级。
  # 但只在“本轮成功”时恢复降级原因：fix_error_*/skipped_locked 是更具体的故障，
  # 不能被降级原因覆盖，否则 status.json 看不到真正的错误。
  if [ "$REASON" = "ok" ] && [ "$MODE" = "poll" ]; then
    if [ -n "$POLL_REASON" ]; then
      REASON=$POLL_REASON
    elif [ -n "$PIPE_REASON" ]; then
      REASON=$PIPE_REASON
    fi
  fi
  # 假活是“仍在事件模式但收不到事件”，不能被本轮 ok 洗掉。
  if [ "$BLIND" = 1 ] && [ "$MODE" = "event" ]; then
    REASON=blind
  fi
  write_status
  publish
}

LOCK=$DATA/.daemon.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  lp=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -z "$lp" ]; then
    # 另一个实例可能刚 mkdir、还没写 pid：给它 2 秒，别当陈旧锁删掉。
    i=0
    while [ "$i" -lt 10 ]; do
      sleep 0.2 2>/dev/null || sleep 1
      lp=$(cat "$LOCK/pid" 2>/dev/null)
      [ -n "$lp" ] && break
      i=$((i+1))
    done
  fi
  if [ -n "$lp" ] && [ -d "/proc/$lp" ] && \
     tr '\0' ' ' < "/proc/$lp/cmdline" 2>/dev/null | grep -q 'si-mount-eventd\.sh'; then
    exit 0                      # 活着的确实是另一个守护：让位（不按时间判陈旧）
  fi
  rm -rf "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo "$$" > "$LOCK/pid"
trap 'if [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]; then rm -rf "$LOCK" 2>/dev/null; fi' EXIT
trap 'if [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]; then rm -rf "$LOCK" 2>/dev/null; fi; exit 0' INT TERM HUP

rm -f "$MOD/module.prop.tmp."* "$SNAP".* 2>/dev/null
# .repairs 只留 1 小时/200 行；--trim-only 自己抢锁，有活 fix 时自动跳过（不额外判断锁目录）。
timeout 5 sh "$FIX" --trim-only >/dev/null 2>&1

MODE=starting; REASON=boot; write_status
dbg "starting status written"
publish force
dbg "starting publish done"

if [ "$ENABLED" != "1" ]; then
  MODE=off; REASON=disabled; write_status; publish force
  log "已停用（ENABLED=0）"
  exit 0
fi

if [ "$CFG_MODE" = "poll" ]; then
  # 用户强制轮询：完全不碰 tracefs/实例。
  MODE=poll; REASON=forced_poll
else
  dbg "tracefs wait start"
  i=0
  # 显式 SI_TRACE（自测/特殊 ROM）不再等系统路径。
  while [ "$i" -lt 30 ] && [ -z "$SI_TRACE" ] \
        && [ ! -e /sys/kernel/tracing/kprobe_events ] \
        && [ ! -e /sys/kernel/debug/tracing/kprobe_events ]; do
    sleep 1; i=$((i+1))
  done

  T=""
  if [ -n "$SI_TRACE" ]; then
    [ -w "$SI_TRACE/kprobe_events" ] 2>/dev/null && T=$SI_TRACE
  else
    for c in /sys/kernel/tracing /sys/kernel/debug/tracing; do
      if [ -w "$c/kprobe_events" ] 2>/dev/null; then T=$c; break; fi
    done
  fi

  dbg "tracefs T=${T:-none}"
  if [ -z "$T" ]; then
    MODE=poll; REASON=tracefs_missing; TRACEFS=""
  else
    TRACEFS=$T
    INST=$T/instances/$INST_NAME
    need_rebuild=0
    if [ ! -d "$INST" ]; then
      need_rebuild=1
    elif [ ! -e "$INST/trace_pipe" ] && [ ! -L "$INST/trace_pipe" ]; then
      need_rebuild=1
    elif pipe_open_ok "$INST/trace_pipe"; then
      dbg "pipe probe ok"
      # 通道空闲且实例/tracing_on/kprobe 齐全：复用，绝不删 kprobe/rmdir。
      if [ "$(cat "$INST/tracing_on" 2>/dev/null)" = "1" ] \
         && [ -e "$T/events/kprobes/si_fix_pu/enable" ] \
         && [ -e "$T/events/kprobes/si_fix_pm/enable" ] \
         && [ -e "$INST/events/kprobes/si_fix_pu/enable" ] \
         && [ -e "$INST/events/kprobes/si_fix_pm/enable" ] \
         && grep -q '^p:.*si_fix_pu' "$T/kprobe_events" 2>/dev/null \
         && grep -q '^p:.*si_fix_pm' "$T/kprobe_events" 2>/dev/null; then
        for e in si_fix_pu si_fix_pm; do
          echo 'comm != "nsenter" && comm != "magiskd" && comm != "mount" && comm != "umount"' > "$INST/events/kprobes/$e/filter" 2>/dev/null
          echo 1 > "$INST/events/kprobes/$e/enable" 2>/dev/null
        done
        echo 128 > "$INST/buffer_size_kb" 2>/dev/null
        echo 1 > "$INST/tracing_on" 2>/dev/null
        MODE=event; REASON=ok
        log "复用已有 trace 实例（不删 kprobe、不 rmdir）"
      else
        need_rebuild=1
      fi
    else
      # pipe 打不开：先扫 /proc/*/fd 找活持有者；有 holder 就保持共享实例不动。
      dbg "pipe probe failed; holder scan start"
      pipe_has_holder "$INST/trace_pipe"; _ph=$?
      if [ "$_ph" = 0 ] || [ "$_ph" = 2 ]; then
        PIPE_DEGRADED=1
        MODE=poll; REASON=pipe_busy; PIPE_REASON=pipe_busy
        if [ "$_ph" = 0 ]; then
          log "trace_pipe 有活持有者，降级轮询（不拆实例、不删 kprobe）"
        else
          log "trace_pipe 占用者扫描超时，按 busy 保守降级轮询（不拆实例）"
        fi
      else
        # 无 holder 的坏实例可安全重建一次，避免在 poll_loop 里永久打转。
        log "trace_pipe 打不开且无持有者，尝试重建一次"
        need_rebuild=1
      fi
      dbg "holder scan done"
    fi

    if [ "$need_rebuild" = 1 ]; then
      # 只有确认通道空闲/不存在才重建：先拆旧实例再动 kprobe，否则旧实例占着事件，
      # kprobe 删不掉，重注册会一直 "already exists"。
      if [ -d "$INST" ]; then
        echo 0 > "$INST/events/enable" 2>/dev/null
        echo 0 > "$INST/tracing_on" 2>/dev/null
        rmdir "$INST" 2>/dev/null || rm -rf "$INST" 2>/dev/null
      fi
      for e in si_fix_pu si_fix_pm; do
        grep -q "kprobes/$e" "$T/kprobe_events" 2>/dev/null && echo "-:kprobes/$e" >> "$T/kprobe_events" 2>/dev/null
      done
      for sym in path_umount ksys_umount do_umount; do
        echo "p:si_fix_pu $sym" >> "$T/kprobe_events" 2>/dev/null
        [ -e "$T/events/kprobes/si_fix_pu/enable" ] && break
      done
      for sym in path_mount ksys_mount do_mount; do
        echo "p:si_fix_pm $sym" >> "$T/kprobe_events" 2>/dev/null
        [ -e "$T/events/kprobes/si_fix_pm/enable" ] && break
      done

      if [ ! -e "$T/events/kprobes/si_fix_pu/enable" ] || [ ! -e "$T/events/kprobes/si_fix_pm/enable" ]; then
        MODE=poll; REASON=kprobe_failed
        log "kprobe 创建失败，降级轮询"
      else
        echo 0 > "$T/events/kprobes/si_fix_pu/enable" 2>/dev/null
        echo 0 > "$T/events/kprobes/si_fix_pm/enable" 2>/dev/null
        mkdir -p "$INST" 2>/dev/null
        echo 0 > "$INST/events/enable" 2>/dev/null
        # 自检本身用 mount/umount 命令触发事件（kprobe 记录的 comm 就是 mount/umount），
        # 所以自检期间先不排除它们；自检通过后再写最终 filter，否则自检永远收不到事件。
        for e in si_fix_pu si_fix_pm; do
          echo 'comm != "nsenter" && comm != "magiskd"' > "$INST/events/kprobes/$e/filter" 2>/dev/null
          echo 1 > "$INST/events/kprobes/$e/enable" 2>/dev/null
        done
        echo 128 > "$INST/buffer_size_kb" 2>/dev/null
        echo 1 > "$INST/tracing_on" 2>/dev/null

        # 自检：mount 与 umount 两侧都要命中。
        mkdir -p "$DATA/.sitest" 2>/dev/null
        echo > "$INST/trace" 2>/dev/null
        unshare -m sh -c 'mount -t tmpfs none '"$DATA"'/.sitest 2>/dev/null; umount '"$DATA"'/.sitest 2>/dev/null' 2>/dev/null
        sleep 1
        ok_pm=0; ok_pu=0
        grep -q 'si_fix_pm' "$INST/trace" 2>/dev/null && ok_pm=1
        grep -q 'si_fix_pu' "$INST/trace" 2>/dev/null && ok_pu=1
        echo > "$INST/trace" 2>/dev/null
        rmdir "$DATA/.sitest" 2>/dev/null || rm -rf "$DATA/.sitest" 2>/dev/null
        if [ "$ok_pm" = 1 ] && [ "$ok_pu" = 1 ] \
           && [ -e "$INST/events/kprobes/si_fix_pu/enable" ] \
           && [ -e "$INST/events/kprobes/si_fix_pm/enable" ] \
           && grep -q '^p:.*si_fix_pu' "$T/kprobe_events" 2>/dev/null \
           && grep -q '^p:.*si_fix_pm' "$T/kprobe_events" 2>/dev/null; then
          # 自检通过，再排除我们自己 repair 产生的 mount/umount 事件（防止自触发）。
          for e in si_fix_pu si_fix_pm; do
            echo 'comm != "nsenter" && comm != "magiskd" && comm != "mount" && comm != "umount"' > "$INST/events/kprobes/$e/filter" 2>/dev/null
          done
          MODE=event; REASON=ok
        else
          MODE=poll; REASON=selftest_failed
          log "自检/实例 kprobe 校验失败（pm=$ok_pm pu=$ok_pu），降级轮询"
        fi
      fi
    fi
  fi
fi

if [ "$CFG_MODE" = "event" ] && [ "$MODE" = "poll" ] && [ "$PIPE_DEGRADED" != 1 ]; then
  REASON="${REASON}+forced_event_unsupported"
  log "配置要求 event，但环境不支持（$REASON），保守走轮询"
fi

# 只有确定实例归我们管（不是 pipe 降级）时才关 tracing_on/events。
if [ "$MODE" = "poll" ] && [ "$PIPE_DEGRADED" != 1 ] && [ -n "$INST" ] && [ -d "$INST" ]; then
  echo 0 > "$INST/events/enable" 2>/dev/null
  echo 0 > "$INST/tracing_on" 2>/dev/null
fi

dbg "startup result mode=$MODE reason=$REASON"
write_status
publish force
log "启动 mode=$MODE reason=$REASON version=$VERSION"

# 降级原因要在轮询期间保持可见：run_fix 成功会把 REASON 置 ok，status 上就看
# 不到 tracefs/kprobe/selftest/forced_poll 了。
POLL_REASON=""
if [ "$MODE" = "poll" ]; then
  case "$REASON" in
    ok|boot|boot_wait|fuse_missing|skipped_locked|fix_error_*) ;;
    *) POLL_REASON=$REASON ;;
  esac
fi

# kprobe/selftest 失败后不要立刻 exit：supervisor 30s 重启会让“失败→轮询→重启”
# 形成快速循环；改成 600s 退避一次，给内核/实例状态一个恢复窗口。
case "$MODE:$REASON" in
  poll:kprobe_failed|poll:selftest_failed|poll:*+forced_event_unsupported)
    EVENT_RETRY_AT=$(( $(mono) + 600 ))
    log "事件模式不可用（$REASON），600s 后再尝试"
    ;;
esac

run_fix

poll_loop() {
  log "进入轮询模式，间隔 ${POLL_INTERVAL}s"
  _next_fix=$(( $(now_s) + POLL_INTERVAL ))
  _next_probe=$(( $(now_s) + PIPE_PROBE_EVERY ))
  while true; do
    _now=$(now_s)
    if [ "$PIPE_DEGRADED" = 1 ] && [ -n "$INST" ]; then
      # pipe 降级：按 POLL_INTERVAL 轮询并定期重探，探到空闲就退出；绝不在这里拆实例。
      _t=$(( _next_fix - _now ))
      [ "$_t" -gt "$PIPE_PROBE_EVERY" ] && _t=$PIPE_PROBE_EVERY
      case "$REASON" in
        boot_wait)    [ "$_t" -gt 5 ] && _t=5 ;;
        fuse_missing) [ "$_t" -gt "$FUSE_RETRY" ] && _t=$FUSE_RETRY ;;
      esac
      [ "$_t" -lt 1 ] && _t=1
      sleep "$_t"
      _now=$(now_s)
      if [ "$_now" -ge "$_next_probe" ]; then
        _next_probe=$(( _now + PIPE_PROBE_EVERY ))
        if pipe_open_ok "$INST/trace_pipe"; then
          log "trace_pipe 已空闲，退出让 supervisor 重启事件模式"
          exit 0
        fi
      fi
      if [ "$_now" -lt "$_next_fix" ]; then
        case "$REASON" in
          boot_wait|fuse_missing) _next_fix=$_now ;;
          *) continue ;;
        esac
      fi
    else
      case "$REASON" in
        boot_wait)    sleep 5 ;;
        fuse_missing) sleep "$FUSE_RETRY" ;;
        *)
          # young/churn 会设置 RETRY_AT（MIN_AGE+2 / 熔断到期）；轮询模式也要消费它，
          # 否则 README 承诺的“稍后补扫”要等满一个 POLL_INTERVAL。
          _sleep=$POLL_INTERVAL
          if [ "$RETRY_AT" -gt 0 ]; then
            _t=$(( RETRY_AT - $(mono) ))
            [ "$_t" -ge 1 ] && [ "$_t" -lt "$_sleep" ] && _sleep=$_t
          fi
          sleep "$_sleep"
          ;;
      esac
      _now=$(now_s)
    fi
    # 轮询期间 tracefs 可用时退出，让 supervisor 以事件模式重启。
    # 注意：只对 tracefs_missing 做“一出现就重试”；kprobe/selftest 失败走 600s 退避，
    # 否则每次重启都会再次失败，形成每 ~90s 一次的 daemon 重启循环。
    # 判据与启动一致（必须可写）：只读 tracefs 会让“重启→又缺 tracefs→再退出”打转。
    # REASON 可能带 +forced_event_unsupported 后缀，用 case 前缀匹配。
    case "$REASON" in
      tracefs_missing*)
        if [ -n "$SI_TRACE" ]; then
          [ -w "$SI_TRACE/kprobe_events" ] 2>/dev/null && { log "检测到 tracefs 可写，尝试切回事件模式"; exit 0; }
        else
          for _c in /sys/kernel/tracing /sys/kernel/debug/tracing; do
            [ -w "$_c/kprobe_events" ] 2>/dev/null && { log "检测到 tracefs 可写，尝试切回事件模式"; exit 0; }
          done
        fi
        ;;
    esac
    if [ "$EVENT_RETRY_AT" -gt 0 ] && [ "$(mono)" -ge "$EVENT_RETRY_AT" ]; then
      log "事件模式退避到期（reason=$REASON），重启后重试"
      exit 0
    fi
    run_fix
    _next_fix=$(( $(now_s) + POLL_INTERVAL ))
  done
}

if [ "$MODE" = "event" ] && ! pipe_open_ok "$INST/trace_pipe"; then
  # 进入事件循环前再探一次，缩小 probe→exec 窗口。失败只降级：绝不关共享实例的
  # tracing_on/events、不删实例/kprobe，也不清 trace（可能是别人尚未消费的缓冲）。
  MODE=poll; PIPE_DEGRADED=1
  pipe_has_holder "$INST/trace_pipe"; _ph=$?
  if [ "$_ph" = 0 ] || [ "$_ph" = 2 ]; then
    REASON=pipe_busy; PIPE_REASON=pipe_busy
    log "进入事件循环前 trace_pipe 有活持有者/占用未知，降级轮询（不拆实例）"
  else
    REASON=pipe_open_error; PIPE_REASON=pipe_open_error
    log "进入事件循环前 trace_pipe 打不开且无持有者，降级轮询（不拆实例）"
  fi
  write_status; publish force
fi

if [ "$MODE" = "event" ]; then
  # 不用 2>/dev/null 包 exec：无命令 exec 会永久改写 stderr；失败交给 supervisor 重启。
  exec 3< "$INST/trace_pipe"
  NEXT_SCAN=$(( $(mono) + HEALTH ))
  NEXT_BLIND=$(( $(mono) + BLIND_EVERY ))

  while true; do
    _nowm=$(mono)
    # 事件风暴时 read 立即返回，到期检查必须放在读之前，否则 RETRY_AT 会被饿死。
    if [ "$RETRY_AT" -gt 0 ] && [ "$_nowm" -ge "$RETRY_AT" ]; then
      RETRY_AT=0
      health
      run_fix
      NEXT_SCAN=$(( $(mono) + HEALTH ))
      continue
    fi
    if [ "$NEXT_BLIND" -gt 0 ] && [ "$_nowm" -ge "$NEXT_BLIND" ]; then
      sample_blind
      NEXT_BLIND=$(( _nowm + BLIND_EVERY ))
    fi
    # 时基切换/跳时：重新钉住三个到期点，否则旧时基的 deadline 永久不到期。
    if [ "$NEXT_SCAN" -gt 0 ] && [ $(( NEXT_SCAN - _nowm )) -gt "$HEALTH" ]; then
      NEXT_SCAN=$(( _nowm + HEALTH ))
    fi
    if [ "$NEXT_BLIND" -gt 0 ] && [ $(( NEXT_BLIND - _nowm )) -gt "$BLIND_EVERY" ]; then
      NEXT_BLIND=$(( _nowm + BLIND_EVERY ))
    fi
    # churn 重试最长 600s，超过 1h 才像时基跳变。
    if [ "$RETRY_AT" -gt 0 ] && [ $(( RETRY_AT - _nowm )) -gt 3600 ]; then
      RETRY_AT=0
    fi
    t=$HEALTH
    [ "$NEXT_SCAN" -gt 0 ] && t=$(( NEXT_SCAN - _nowm ))
    [ "$NEXT_BLIND" -gt 0 ] && [ $(( NEXT_BLIND - _nowm )) -lt "$t" ] && t=$(( NEXT_BLIND - _nowm ))
    if [ "$RETRY_AT" -gt 0 ]; then
      _rt=$(( RETRY_AT - _nowm ))
      [ "$_rt" -lt "$t" ] && t=$_rt
    fi
    [ "$t" -gt "$HEALTH" ] && t=$HEALTH
    [ "$t" -lt 1 ] && t=1

    # 退出码必须紧跟 read 取，放在 if 之后会被“未命中返回 0”吞掉。
    t_start=$(mono)
    read -t "$t" -r line <&3
    rc=$?
    if [ "$rc" -eq 0 ]; then
      case "$line" in
        *si_fix_pu:*|*si_fix_pm:*) ;;
        *) continue ;;
      esac
      LAST_EVENT=$(now_s)
      if [ "$BLIND" = 1 ]; then
        BLIND=0; BLIND_SINCE=0; BLIND_HITS=0; REASON=ok
        log "收到事件，事件通道已恢复"
        write_status; publish force
      fi
      # FUSE 等待期只由 RETRY_AT 退避驱动，事件不绕过退避。
      if [ "$REASON" = "boot_wait" ] || [ "$REASON" = "fuse_missing" ]; then
        continue
      fi
      # 刚修完 <1 秒：立即复检，让 churn 的 <1 秒判据可达。
      _nowms=$(date +%s%3N 2>/dev/null)
      _recent=0
      ms_recent "$LAST_FIX_MS" "$_nowms" && _recent=1
      if [ "$_recent" = 0 ]; then
        # 尾部去抖：1 秒内没有新事件就开修（同时充当下落定窗口）。
        n=0; dstart=$(mono)
        while [ "$n" -lt 6 ]; do
          read -t 1 -r _l <&3 || break
          n=$((n+1))
          [ $(( $(mono) - dstart )) -ge 4 ] && break
        done
      fi
      run_fix
      [ "$_recent" = 1 ] && LAST_RUN=$(now_s)   # 立即复检一次后回到 2 秒门
      # 吸掉自己 mount 产生的事件（最多 3 秒）；有像样的事件被吸进来就排补扫，别吃掉。
      n=0; got=0
      while [ "$n" -lt 3 ]; do
        read -t 1 -r _l <&3 || break
        case "$_l" in
          *si_fix_pu:*|*si_fix_pm:*) got=1; break ;;
        esac
        n=$((n+1))
      done
      if [ "$got" = 1 ]; then
        _nowms=$(date +%s%3N 2>/dev/null)
        _recent=0
        ms_recent "$LAST_FIX_MS" "$_nowms" && _recent=1
        if [ "$_recent" = 1 ]; then
          # 修复后 <1 秒又被拆：立刻复检，让熔断的 <1 秒判据生效。
          run_fix
          LAST_RUN=$(now_s)
        else
          RETRY_AT=$(( $(mono) + 3 ))
        fi
      fi
      NEXT_SCAN=$(( $(mono) + HEALTH ))
      continue
    fi

    # mksh 读超时返回 142，真 EOF 返回 ≤128；少数 shell 返回 1，用“等了多久”再兜一层。
    el=$(( $(mono) - t_start ))
    timed_out=0
    [ "$rc" -gt 128 ] && timed_out=1
    [ "$rc" -le 128 ] && [ "$el" -ge $((t - 1)) ] && timed_out=1

    if [ "$timed_out" = "0" ]; then
      MODE=off; REASON=pipe_closed; write_status; publish force
      log "trace_pipe 关闭（rc=$rc，等 ${el}s），退出"
      exit 1
    fi

    _nowm=$(mono)
    if [ "$NEXT_BLIND" -gt 0 ] && [ "$_nowm" -ge "$NEXT_BLIND" ]; then
      sample_blind
      NEXT_BLIND=$(( _nowm + BLIND_EVERY ))
    fi
    if [ "$RETRY_AT" -gt 0 ] && [ "$_nowm" -ge "$RETRY_AT" ]; then
      RETRY_AT=0
      health
      run_fix
      NEXT_SCAN=$(( $(mono) + HEALTH ))
    elif [ "$NEXT_SCAN" -gt 0 ] && [ "$_nowm" -ge "$NEXT_SCAN" ]; then
      RETRY_AT=0
      health
      run_fix
      NEXT_SCAN=$(( $(mono) + HEALTH ))
    fi
    publish
  done
else
  poll_loop
fi
