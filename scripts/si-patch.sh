#!/system/bin/sh
# si-patch.sh — Android 17（SDK 37）下 SI 应用列表为空的可选修复。
#
# 只替换 /data/adb/storage-isolation/bin/server-v355.dex：
#   原版 331,520 B / sha256 c410e8924da1a08f8fe05d8e5d36cae5eb1cb6a192bca219f9b940471db08d7a
#   补丁 380,692 B / sha256 48ff195edf6225011404b4e914ecb7f742d1b0ff01f8e6fb60469fdec6b3c679
# 补丁 dex 由酷安用户「无所事事」提供，随模块 assets/server-v355.dex 分发；不要修改内容。
# 适用 SI 版本取自 module.prop 的 siPatchVersion / siPatchServer，脚本里不写版本字面量。
#
# 用法：sh si-patch.sh check|status|apply|restore [--force]
#   check          输出 KEY=VALUE
#   status         给人看的一行状态
#   apply          仅 SDK=37、SI 版本适用、路径存在且为原版时执行；先备份、再校验、失败回滚
#   restore        当前为补丁版时，从新到旧找第一份 sha==原版的备份恢复
#   restore --force 当前不是补丁版（如 unknown）但存在有效原版备份时，显式覆盖恢复
#
# 只碰 server-v355.dex：不改 main.dex、不改 SI 配置、不动 SI 的其它文件，也不自动重启 SI。
LC_ALL=C
export LC_ALL

ORIGINAL_SHA=c410e8924da1a08f8fe05d8e5d36cae5eb1cb6a192bca219f9b940471db08d7a
PATCH_SHA=48ff195edf6225011404b4e914ecb7f742d1b0ff01f8e6fb60469fdec6b3c679
SERVER=server-v355.dex

case "$0" in */*) D=${0%/*} ;; *) D=. ;; esac
MODDIR=${SI_MOD:-$D/..}
DATA=${SI_DATA:-/data/adb/si-mount-fix}
BIN=/data/adb/storage-isolation/bin
ASSET=$MODDIR/assets/$SERVER
CP=cp

# 测试钩子只在 SI_TEST=1 时生效，生产环境忽略残留变量。
# SI_PATCH_ORIGINAL_SHA 让测试用小样本扮演“原版”；补丁哈希始终用真实值。
if [ "$SI_TEST" = 1 ]; then
  [ -n "${SI_PATCH_DATA:-}" ] && DATA=$SI_PATCH_DATA
  [ -n "${SI_PATCH_BIN:-}" ] && BIN=$SI_PATCH_BIN
  [ -n "${SI_PATCH_ASSET:-}" ] && ASSET=$SI_PATCH_ASSET
  [ -n "${SI_PATCH_ORIGINAL_SHA:-}" ] && ORIGINAL_SHA=$SI_PATCH_ORIGINAL_SHA
  [ -n "${SI_PATCH_CP:-}" ] && CP=$SI_PATCH_CP
fi
DEX=$BIN/$SERVER
BACKUP_DIR=$DATA/patch-backup
LOCK=$DATA/.si-patch.lock
PROP=$MODDIR/module.prop

# 适用版本只来自 module.prop；缺失时 SI_MATCH=0，apply 会拒绝执行。
PATCH_FOR_VERSION=
PATCH_FOR_SERVER=
if [ -r "$PROP" ]; then
  PATCH_FOR_VERSION=$(sed -n 's/^siPatchVersion=//p' "$PROP" 2>/dev/null | head -1)
  PATCH_FOR_SERVER=$(sed -n 's/^siPatchServer=//p' "$PROP" 2>/dev/null | head -1)
fi

detect_sdk() {
  if [ "$SI_TEST" = 1 ] && [ -n "${SI_PATCH_SDK:-}" ]; then
    printf '%s\n' "$SI_PATCH_SDK"
    return 0
  fi
  getprop ro.build.version.sdk 2>/dev/null | tr -d '[:space:]'
}

detect_si_version() {
  if [ "$SI_TEST" = 1 ] && [ -n "${SI_PATCH_VERSION:-}" ]; then
    printf '%s\n' "$SI_PATCH_VERSION"
    return 0
  fi
  command -v dumpsys >/dev/null 2>&1 || return 1
  if command -v timeout >/dev/null 2>&1; then
    _dump=$(timeout 5 dumpsys package moe.shizuku.redirectstorage 2>/dev/null)
  else
    _dump=$(dumpsys package moe.shizuku.redirectstorage 2>/dev/null)
  fi
  printf '%s\n' "$_dump" | sed -n 's/^[[:space:]]*versionName=//p' | head -1
}

sha256_of() {
  [ -f "$1" ] || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

file_size() {
  wc -c < "$1" 2>/dev/null | tr -d '[:space:]'
}

# 备份文件名是 server-v355.dex.<YYYYmmdd-HHMMSS>[.<序号>]；临时文件以点开头，不会混进来。
list_backups() {
  [ -d "$BACKUP_DIR" ] || return 0
  for _b in "$BACKUP_DIR/$SERVER".*; do
    [ -f "$_b" ] || continue
    case "${_b##*/}" in
      *".tmp."*) continue ;;
    esac
    printf '%s\n' "$_b"
  done
}

count_backups() {
  list_backups | wc -l | tr -d '[:space:]'
}

# 从新到旧扫描，返回第一份 sha256 等于原版的备份；没有则输出空。
find_original_backup() {
  list_backups | sort -r | while IFS= read -r _b; do
    [ -n "$_b" ] || continue
    if [ "$(sha256_of "$_b")" = "$ORIGINAL_SHA" ]; then
      printf '%s\n' "$_b"
      break
    fi
  done
}

si_version_ok() {
  [ -n "$PATCH_FOR_VERSION" ] || return 1
  # versionName 读不到时，固定路径 server-v355.dex 本身就是适用范围内的证据。
  [ -n "$SI_VERSION" ] || return 0
  case "$SI_VERSION" in
    "$PATCH_FOR_VERSION"*) return 0 ;;
  esac
  return 1
}

SDK=$(detect_sdk)
SI_VERSION=$(detect_si_version)
SIZE=0
SHA=
DEX_EXISTS=0
STATE=
SI_MATCH=0
BACKUP_COUNT=0
BACKUP_OK=0
PROMPTED=0
FORCE=0
TMP_TARGET=
TMP_CUR=
BACKUP=
LOCK_HELD=0

collect_state() {
  SDK=${SDK:-unknown}
  SIZE=0
  SHA=
  DEX_EXISTS=0
  if [ -f "$DEX" ]; then
    DEX_EXISTS=1
    _size=$(file_size "$DEX")
    case "$_size" in
      ''|*[!0-9]*) SIZE=0 ;;
      *) SIZE=$_size ;;
    esac
    SHA=$(sha256_of "$DEX")
  fi
  SI_MATCH=0
  if si_version_ok; then SI_MATCH=1; fi
  BACKUP_COUNT=$(count_backups)
  BACKUP_OK=0
  if [ -n "$(find_original_backup)" ]; then BACKUP_OK=1; fi
  if [ -f "$DATA/.patch_prompted" ]; then PROMPTED=1; else PROMPTED=0; fi

  if [ "$SDK" != 37 ]; then
    STATE=unsupported
  elif [ "$DEX_EXISTS" != 1 ]; then
    STATE=no-si
  elif [ "$SHA" = "$ORIGINAL_SHA" ]; then
    STATE=original
  elif [ "$SHA" = "$PATCH_SHA" ]; then
    STATE=patched
  else
    STATE=unknown
  fi
}

print_check() {
  printf 'STATE=%s\n' "$STATE"
  printf 'SDK=%s\n' "$SDK"
  printf 'SI_VERSION=%s\n' "${SI_VERSION:-}"
  printf 'SI_TARGET_VERSION=%s\n' "${PATCH_FOR_VERSION:-}"
  printf 'SI_TARGET_SERVER=%s\n' "${PATCH_FOR_SERVER:-}"
  printf 'SI_MATCH=%s\n' "$SI_MATCH"
  printf 'DEX=%s\n' "$DEX"
  printf 'SIZE=%s\n' "$SIZE"
  printf 'SHA=%s\n' "${SHA:-}"
  printf 'BACKUP_COUNT=%s\n' "$BACKUP_COUNT"
  printf 'BACKUP_OK=%s\n' "$BACKUP_OK"
  printf 'PROMPTED=%s\n' "$PROMPTED"
}

status_line() {
  case "$STATE" in
    unsupported)
      printf 'SI 补丁：不适用（Android SDK %s，仅支持 SDK 37）\n' "$SDK" ;;
    no-si)
      printf 'SI 补丁：未检测到 SI 的 %s（%s）\n' "$SERVER" "$DEX" ;;
    original)
      if [ "$SI_MATCH" = 1 ]; then
        printf 'SI 补丁：可应用（SI %s，原版 %s）\n' "${SI_VERSION:-版本未知}" "$SERVER"
      else
        printf 'SI 补丁：不适用（当前 SI %s，仅适用于 %s / %s）\n' \
          "${SI_VERSION:-版本未知}" "${PATCH_FOR_VERSION:-未知版本}" "${PATCH_FOR_SERVER:-$SERVER}"
      fi ;;
    patched)
      if [ "$BACKUP_OK" = 1 ]; then
        printf 'SI 补丁：已应用（可恢复原版）\n'
      else
        printf 'SI 补丁：已应用（没有可用的原版备份）\n'
      fi ;;
    *)
      if [ "$BACKUP_OK" = 1 ]; then
        printf 'SI 补丁：版本不匹配，未动（有可用的原版备份，可强制恢复）\n'
      else
        printf 'SI 补丁：版本不匹配，未动（sha256 %s）\n' "${SHA:-读取失败}"
      fi ;;
  esac
}

die() {
  printf 'si-patch: %s\n' "$1" >&2
  exit "${2:-1}"
}

log_action() {
  _ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
  [ -n "$_ts" ] || _ts=$(date +%s 2>/dev/null)
  printf '%s %s\n' "${_ts:-?}" "$*" >> "$DATA/patch.log" 2>/dev/null
  chmod 600 "$DATA/patch.log" 2>/dev/null
}

release_lock() {
  [ "$LOCK_HELD" = 1 ] || return 0
  if [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$LOCK" 2>/dev/null
  fi
  LOCK_HELD=0
}

cleanup() {
  if [ -n "$TMP_TARGET" ]; then rm -f "$TMP_TARGET" 2>/dev/null; fi
  if [ -n "$TMP_CUR" ]; then rm -f "$TMP_CUR" 2>/dev/null; fi
  release_lock
  return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

acquire_lock() {
  mkdir -p "$DATA" 2>/dev/null || die "无法创建数据目录 $DATA" 3
  chmod 700 "$DATA" 2>/dev/null
  if ! mkdir "$LOCK" 2>/dev/null; then
    _lp=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -z "$_lp" ]; then
      # 另一个进程刚 mkdir、还没写 pid：给 1 秒，别把活锁当陈旧锁抢掉。
      _i=0
      while [ "$_i" -lt 10 ]; do
        sleep 0.1 2>/dev/null || sleep 1
        _lp=$(cat "$LOCK/pid" 2>/dev/null)
        [ -n "$_lp" ] && break
        _i=$((_i + 1))
      done
    fi
    if [ -n "$_lp" ] && [ -d "/proc/$_lp" ] && \
       tr '\0' ' ' < "/proc/$_lp/cmdline" 2>/dev/null | grep -q 'si-patch\.sh'; then
      die "另一个补丁操作正在进行（PID $_lp），请稍后再试" 4
    fi
    rm -rf "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || die "无法创建锁目录 $LOCK" 3
  fi
  chmod 700 "$LOCK" 2>/dev/null
  printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null || {
    rm -rf "$LOCK" 2>/dev/null
    die "无法写锁文件 $LOCK/pid" 3
  }
  chmod 600 "$LOCK/pid" 2>/dev/null
  LOCK_HELD=1
}

# 把 $1 复制到目标 dex：临时文件里 chown/chmod、校验 $2，再原子替换。
install_file() {
  _src=$1
  _want=$2
  _tmp=$BIN/.$SERVER.new.$$
  TMP_TARGET=$_tmp
  if ! "$CP" "$_src" "$_tmp"; then
    rm -f "$_tmp" 2>/dev/null
    TMP_TARGET=
    return 1
  fi
  # 真机为 root；测试可用 SI_PATCH_CHOWN 注入可记录的命令，CI 非 root 也能覆盖这一步。
  if [ "$SI_TEST" = 1 ] && [ -n "${SI_PATCH_CHOWN:-}" ]; then
    if ! "$SI_PATCH_CHOWN" root:root "$_tmp" 2>/dev/null; then
      rm -f "$_tmp" 2>/dev/null
      TMP_TARGET=
      return 1
    fi
  elif [ "$(id -u 2>/dev/null)" = 0 ]; then
    if ! chown root:root "$_tmp" 2>/dev/null; then
      rm -f "$_tmp" 2>/dev/null
      TMP_TARGET=
      return 1
    fi
  fi
  if ! chmod 600 "$_tmp" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null
    TMP_TARGET=
    return 1
  fi
  _got=$(sha256_of "$_tmp")
  if [ "$_got" != "$_want" ]; then
    rm -f "$_tmp" 2>/dev/null
    TMP_TARGET=
    return 1
  fi
  if ! mv -f "$_tmp" "$DEX" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null
    TMP_TARGET=
    return 1
  fi
  TMP_TARGET=
  # 测试钩子：mv 之后故意写坏目标，验证最后一道 sha256 校验和回滚确实生效。
  if [ "$SI_TEST" = 1 ] && [ -n "${SI_PATCH_CORRUPT_AFTER_MV:-}" ] \
     && [ ! -e "$SI_PATCH_CORRUPT_AFTER_MV" ]; then
    : > "$SI_PATCH_CORRUPT_AFTER_MV" 2>/dev/null
    printf 'si-patch test corruption\n' > "$DEX" 2>/dev/null
  fi
  _got=$(sha256_of "$DEX")
  [ "$_got" = "$_want" ]
}

create_backup() {
  mkdir -p "$BACKUP_DIR" 2>/dev/null || die "无法创建备份目录 $BACKUP_DIR" 5
  chmod 700 "$BACKUP_DIR" 2>/dev/null
  _ts=$(date '+%Y%m%d-%H%M%S' 2>/dev/null)
  [ -n "$_ts" ] || _ts=$(date +%s 2>/dev/null)
  _tmp=$BACKUP_DIR/.$SERVER.$_ts.tmp.$$
  BACKUP=$BACKUP_DIR/$SERVER.$_ts
  _n=0
  while [ -e "$BACKUP" ]; do
    _n=$((_n + 1))
    BACKUP=$BACKUP_DIR/$SERVER.$_ts.$(printf '%03d' "$_n")
  done
  if ! "$CP" "$DEX" "$_tmp"; then
    rm -f "$_tmp" 2>/dev/null
    die "备份原版 dex 失败" 5
  fi
  if ! chmod 600 "$_tmp" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null
    die "设置备份权限失败" 5
  fi
  _got=$(sha256_of "$_tmp")
  if [ "$_got" != "$ORIGINAL_SHA" ]; then
    rm -f "$_tmp" 2>/dev/null
    die "备份校验失败（sha256=${_got:-读取失败}），未改动目标" 5
  fi
  if ! mv -f "$_tmp" "$BACKUP" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null
    die "备份落盘失败" 5
  fi
}

do_apply() {
  collect_state
  case "$STATE" in
    patched)
      printf 'SI 补丁已应用，无需重复操作（恢复原版请用 restore）。\n'
      return 0 ;;
    unsupported)
      die "仅支持 Android 17（SDK 37），当前 SDK=${SDK}" 2 ;;
    no-si)
      die "找不到 $DEX，未检测到可修复的 SI server" 2 ;;
    unknown)
      die "当前 $SERVER 的 sha256 既不是原版也不是补丁版（${SHA:-读取失败}），已拒绝操作" 3 ;;
    original) ;;
    *) die "补丁状态异常（$STATE），已取消" 4 ;;
  esac
  if [ "$SI_MATCH" != 1 ]; then
    die "SI 版本不适用（当前 ${SI_VERSION:-版本未知}，仅适用于 ${PATCH_FOR_VERSION:-未知版本} / ${PATCH_FOR_SERVER:-$SERVER}），未改动目标" 2
  fi

  # 测试钩子：留出窗口把目标改成 patched，验证持锁后会重新读状态，不会覆盖。
  if [ "$SI_TEST" = 1 ] && [ -n "${SI_PATCH_PRELOCK_SLEEP:-}" ]; then
    [ -n "${SI_PATCH_PRELOCK_MARK:-}" ] && : > "$SI_PATCH_PRELOCK_MARK"
    sleep "$SI_PATCH_PRELOCK_SLEEP"
  fi
  acquire_lock
  collect_state
  case "$STATE" in
    patched)
      printf 'SI 补丁已应用，无需重复操作（恢复原版请用 restore）。\n'
      return 0 ;;
    original) ;;
    no-si) die "锁定时目标消失：$DEX" 2 ;;
    unknown) die "锁定后目标哈希变化（${SHA:-读取失败}），已取消" 3 ;;
    *) die "锁定后状态异常：$STATE" 4 ;;
  esac
  if [ "$SI_MATCH" != 1 ]; then
    die "锁定后 SI 版本不适用（当前 ${SI_VERSION:-版本未知}），已取消" 2
  fi

  [ -f "$ASSET" ] || die "模块缺少补丁资产 $ASSET" 5
  _asha=$(sha256_of "$ASSET")
  [ "$_asha" = "$PATCH_SHA" ] \
    || die "补丁资产校验失败（sha256=${_asha:-读取失败}），未改动目标" 5

  create_backup
  if ! install_file "$ASSET" "$PATCH_SHA"; then
    if [ -f "$BACKUP" ] && install_file "$BACKUP" "$ORIGINAL_SHA"; then
      log_action "APPLY-FAILED si=${SI_VERSION:-?} rollback=ok backup=$BACKUP"
      die "写入补丁失败，已自动回滚到原版（备份：$BACKUP）" 5
    fi
    log_action "APPLY-FAILED si=${SI_VERSION:-?} rollback=failed backup=$BACKUP"
    die "写入补丁失败，且自动回滚失败；请用 restore 或手动从 $BACKUP 恢复" 6
  fi
  log_action "APPLY si=${SI_VERSION:-?} original=$ORIGINAL_SHA patched=$PATCH_SHA backup=$BACKUP"
  printf '已应用补丁：%s\n' "$DEX"
  printf '请重新打开存储空间隔离（SI）生效。\n'
}

do_restore() {
  collect_state
  if [ "$DEX_EXISTS" != 1 ]; then
    die "找不到 $DEX，无法恢复" 2
  fi
  if [ "$SHA" = "$ORIGINAL_SHA" ]; then
    die "当前已经是原版，无需恢复" 2
  fi
  _backup=$(find_original_backup)
  if [ -z "$_backup" ]; then
    die "没有可用的原版备份（$BACKUP_DIR），无法恢复" 5
  fi
  if [ "$SHA" != "$PATCH_SHA" ] && [ "$FORCE" != 1 ]; then
    die "当前 $SERVER 不是已知补丁版（${SHA:-读取失败}）；如确认要用原版备份覆盖，请加 --force" 3
  fi

  acquire_lock
  collect_state
  if [ "$SHA" = "$ORIGINAL_SHA" ]; then
    die "补丁状态已变化：当前已经是原版，已取消恢复" 4
  fi
  if [ "$SHA" != "$PATCH_SHA" ] && [ "$FORCE" != 1 ]; then
    die "补丁状态已变化（${SHA:-读取失败}），已取消恢复" 4
  fi
  _backup=$(find_original_backup)
  if [ -z "$_backup" ]; then
    die "没有可用的原版备份（$BACKUP_DIR），已取消恢复" 5
  fi
  _bsha=$(sha256_of "$_backup")
  if [ "$_bsha" != "$ORIGINAL_SHA" ]; then
    die "选中的备份不是原版（sha256=${_bsha:-读取失败}），已拒绝恢复" 5
  fi

  # 先把操作前的目标留一份，恢复过程中失败可以退回去。
  _cur_sha=$SHA
  if [ -z "$_cur_sha" ]; then
    die "当前目标 sha256 读取失败，已取消恢复" 3
  fi
  TMP_CUR=$BIN/.$SERVER.cur.$$
  if ! "$CP" "$DEX" "$TMP_CUR"; then
    rm -f "$TMP_CUR" 2>/dev/null
    TMP_CUR=
    die "保存当前目标副本失败，未改动目标" 5
  fi
  _csha=$(sha256_of "$TMP_CUR")
  if [ "$_csha" != "$_cur_sha" ]; then
    rm -f "$TMP_CUR" 2>/dev/null
    TMP_CUR=
    die "当前目标副本校验失败（sha256=${_csha:-读取失败}），未改动目标" 5
  fi

  if ! install_file "$_backup" "$ORIGINAL_SHA"; then
    if install_file "$TMP_CUR" "$_cur_sha"; then
      log_action "RESTORE-FAILED rollback=ok backup=$_backup"
      die "恢复原版失败，已回到操作前状态（备份：$_backup）" 5
    fi
    log_action "RESTORE-FAILED rollback=failed backup=$_backup"
    # 回滚失败时保留操作前副本，别让 EXIT 清理把它删掉。
    _keep=$TMP_CUR
    TMP_CUR=
    die "恢复原版失败，且回滚失败；操作前副本保留在 $_keep" 6
  fi
  rm -f "$TMP_CUR" 2>/dev/null
  TMP_CUR=
  if [ "$FORCE" = 1 ] && [ "$_cur_sha" != "$PATCH_SHA" ]; then
    log_action "RESTORE-FORCE original=$ORIGINAL_SHA backup=$_backup from=$_cur_sha"
  else
    log_action "RESTORE original=$ORIGINAL_SHA backup=$_backup"
  fi
  printf '已恢复原版：%s\n' "$DEX"
  printf '请重新打开存储空间隔离（SI）生效。\n'
}

case "${1:-}" in
  check) collect_state; print_check ;;
  status) collect_state; status_line ;;
  apply) do_apply ;;
  restore)
    case "${2:-}" in
      '') ;;
      --force) FORCE=1 ;;
      *)
        printf '用法：sh %s restore [--force]\n' "${0##*/}" >&2
        exit 1 ;;
    esac
    do_restore ;;
  *)
    printf '用法：sh %s check|status|apply|restore [--force]\n' "${0##*/}" >&2
    exit 1 ;;
esac
exit 0
