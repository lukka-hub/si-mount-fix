#!/system/bin/sh
# si-patch.sh — Android 17（SDK 37）下 SI 应用列表为空的修复（main.dex）。
#
# 只替换 zygisk-storage-isolation 模块的 main.dex：
#   /data/adb/modules/zygisk-storage-isolation/main.dex
#   原版 90,740 B / sha256 a407674bba778267bac3d50bbdf528fa72fc219f46ef0463ad91bc58a56e82b9
#   补丁 88,336 B / sha256 5413a01b6c49f360f3851af60be8820fcb8a4595d0c15697fcebac88b6d73891
# 社区版 main.dex 已在真机重启验证：server dex 会被 SI daemon 写回原版，但 main.dex 由
# Zygisk 模块在开机时加载，替换后跨重启保持。自建版与社区版指令级一致，仍建议先在目标机型
# 抓 logcat 验证。因此不再修补 server dex，也不重启 SI server。
# 补丁 main.dex 随模块 assets/main.dex 分发，不要修改内容。
# 适用模块与文件名取自 module.prop 的 siPatchModule / siPatchTarget，版本取自
# siPatchVersion / siPatchVersionCode；脚本里不写版本字面量。
#
# 用法：sh si-patch.sh check|status|apply|restore [--force]
#   check          输出 KEY=VALUE，只读文件哈希/大小，不扫 /proc
#   status         给人看的一行状态
#   apply          仅 SDK=37、zygisk 模块适用、目标为原版时执行；先备份、再校验、失败回滚
#   restore        当前为补丁版时，从新到旧找第一份 sha==原版的备份恢复
#   restore --force 当前不是补丁版（如 unknown）但存在有效原版备份时，显式覆盖恢复
#
# 只碰 zygisk-storage-isolation/main.dex：不改 SI 配置、不动 SI 的其它文件；
# apply/restore 成功只提示重启生效，不杀进程、不等待 server。
LC_ALL=C
export LC_ALL

ORIGINAL_SHA=a407674bba778267bac3d50bbdf528fa72fc219f46ef0463ad91bc58a56e82b9
ORIGINAL_SIZE=90740
PATCH_SHA=5413a01b6c49f360f3851af60be8820fcb8a4595d0c15697fcebac88b6d73891
PATCH_SIZE=88336
# 早期社区旧版补丁：可识别、可升级到自建版、可在有原版备份时恢复。
LEGACY_PATCH_SHA=6d4058bc1c66fc14dec2331a603404a59c271d8a4b8f63c5270ff7029a8b80a7
LEGACY_PATCH_SIZE=99104

case "$0" in */*) D=${0%/*} ;; *) D=. ;; esac
MODDIR=${SI_MOD:-$D/..}
DATA=${SI_DATA:-/data/adb/si-mount-fix}
PROP=$MODDIR/module.prop
CP=cp
CHOWN=chown

# 适用模块/文件名/版本只来自 module.prop；缺失时用已知目标兜底，apply 会因版本门禁拒绝。
PATCH_FOR_MODULE=
PATCH_FOR_TARGET=
PATCH_FOR_VERSION=
PATCH_FOR_VERSION_CODE=
if [ -r "$PROP" ]; then
  PATCH_FOR_MODULE=$(sed -n 's/^siPatchModule=//p' "$PROP" 2>/dev/null | head -1)
  PATCH_FOR_TARGET=$(sed -n 's/^siPatchTarget=//p' "$PROP" 2>/dev/null | head -1)
  PATCH_FOR_VERSION=$(sed -n 's/^siPatchVersion=//p' "$PROP" 2>/dev/null | head -1)
  PATCH_FOR_VERSION_CODE=$(sed -n 's/^siPatchVersionCode=//p' "$PROP" 2>/dev/null | head -1)
fi
[ -n "$PATCH_FOR_MODULE" ] || PATCH_FOR_MODULE=zygisk-storage-isolation
[ -n "$PATCH_FOR_TARGET" ] || PATCH_FOR_TARGET=main.dex
TARGET=$PATCH_FOR_TARGET
TARGET_DIR=/data/adb/modules/$PATCH_FOR_MODULE
MODULE_PROP=$TARGET_DIR/module.prop
ASSET=$MODDIR/assets/$TARGET

# 测试钩子只在 SI_TEST=1 时生效，生产环境忽略残留变量。
# ORIGINAL_SHA/SIZE 可换成小样本扮演“原版”；补丁哈希/大小始终用真实值。
if [ "$SI_TEST" = 1 ]; then
  [ -n "${SI_PATCH_DATA:-}" ] && DATA=$SI_PATCH_DATA
  [ -n "${SI_PATCH_TARGET_DIR:-}" ] && TARGET_DIR=$SI_PATCH_TARGET_DIR
  [ -n "${SI_PATCH_ASSET:-}" ] && ASSET=$SI_PATCH_ASSET
  [ -n "${SI_PATCH_ORIGINAL_SHA:-}" ] && ORIGINAL_SHA=$SI_PATCH_ORIGINAL_SHA
  [ -n "${SI_PATCH_ORIGINAL_SIZE:-}" ] && ORIGINAL_SIZE=$SI_PATCH_ORIGINAL_SIZE
  [ -n "${SI_PATCH_LEGACY_SHA:-}" ] && LEGACY_PATCH_SHA=$SI_PATCH_LEGACY_SHA
  [ -n "${SI_PATCH_LEGACY_SIZE:-}" ] && LEGACY_PATCH_SIZE=$SI_PATCH_LEGACY_SIZE
  [ -n "${SI_PATCH_CP:-}" ] && CP=$SI_PATCH_CP
  [ -n "${SI_PATCH_CHOWN:-}" ] && CHOWN=$SI_PATCH_CHOWN
fi
DEX=$TARGET_DIR/$TARGET
MODULE_PROP=$TARGET_DIR/module.prop
# 首次提示标记按目标文件+适用版本区分；旧版单一 .patch_prompted 不再命中。
PROMPT_TAG=$(printf '%s.%s' "$TARGET" "$PATCH_FOR_VERSION" | tr -c 'A-Za-z0-9._-' '_')
PROMPT_FILE=$DATA/.patch_prompted.$PROMPT_TAG
PENDING_FILE=$DATA/patch-pending-reboot
BACKUP_DIR=$DATA/patch-backup
LOCK=$DATA/.si-patch.lock

detect_sdk() {
  if [ "$SI_TEST" = 1 ] && [ -n "${SI_PATCH_SDK:-}" ]; then
    printf '%s\n' "$SI_PATCH_SDK"
    return 0
  fi
  getprop ro.build.version.sdk 2>/dev/null | tr -d '[:space:]'
}

# 启动标识：优先 boot_id；没有时用当前时间减 /proc/uptime 秒数得到本次开机时刻。
# 只读这两个定点文件，不遍历 /proc。
current_boot_id() {
  if [ "$SI_TEST" = 1 ] && [ -n "${SI_PATCH_BOOT_ID:-}" ]; then
    printf '%s\n' "$SI_PATCH_BOOT_ID"
    return 0
  fi
  _bid=
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    _bid=$(sed -n '1p' /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '[:space:]')
  fi
  if [ -n "$_bid" ]; then
    printf 'id:%s\n' "$_bid"
    return 0
  fi
  _up=
  if [ -r /proc/uptime ]; then
    _up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
  fi
  _now=$(date +%s 2>/dev/null)
  case "$_up" in ''|*[!0-9]*) _up= ;; esac
  case "$_now" in ''|*[!0-9]*) _now= ;; esac
  if [ -n "$_up" ] && [ -n "$_now" ]; then
    printf 'uptime:%s\n' "$((_now - _up))"
    return 0
  fi
  return 1
}

mark_pending_reboot() {
  _bid=$(current_boot_id) || return 1
  [ -n "$_bid" ] || return 1
  mkdir -p "$DATA" 2>/dev/null || return 1
  ( umask 077; printf '%s\n' "$_bid" > "$PENDING_FILE" ) 2>/dev/null || return 1
  chmod 600 "$PENDING_FILE" 2>/dev/null
  return 0
}

clear_pending_reboot() {
  rm -f "$PENDING_FILE" 2>/dev/null
}

sha256_of() {
  [ -f "$1" ] || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

file_size() {
  wc -c < "$1" 2>/dev/null | tr -d '[:space:]'
}

target_version() {
  [ -r "$MODULE_PROP" ] || return 0
  sed -n 's/^version=//p' "$MODULE_PROP" 2>/dev/null | head -1
}

target_version_code() {
  [ -r "$MODULE_PROP" ] || return 0
  sed -n 's/^versionCode=//p' "$MODULE_PROP" 2>/dev/null | head -1
}

# 备份文件名是 main.dex.<YYYYmmdd-HHMMSS>[.<序号>]；临时文件以点开头，不会混进来。
list_backups() {
  [ -d "$BACKUP_DIR" ] || return 0
  for _b in "$BACKUP_DIR/$TARGET".*; do
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

# 版本门禁：module.prop 有的字段必须匹配；版本信息完全读不到时，以目标文件存在作为适用范围依据。
version_ok() {
  [ -n "$PATCH_FOR_VERSION" ] || return 1
  if [ -n "$SI_VERSION" ]; then
    _v=${SI_VERSION#v}
    _tv=${PATCH_FOR_VERSION#v}
    [ "$_v" = "$_tv" ] || return 1
  fi
  if [ -n "$PATCH_FOR_VERSION_CODE" ] && [ -n "$SI_VERSION_CODE" ]; then
    [ "$SI_VERSION_CODE" = "$PATCH_FOR_VERSION_CODE" ] || return 1
  fi
  return 0
}

SDK=$(detect_sdk)
[ -n "$SDK" ] || SDK=unknown
SI_VERSION=
SI_VERSION_CODE=
SIZE=0
SHA=
MTIME=0
DEX_EXISTS=0
STATE=
SI_MATCH=0
BACKUP_COUNT=0
BACKUP_OK=0
PROMPTED=0
PENDING_REBOOT=0
FORCE=0
TMP_TARGET=
TMP_CUR=
BACKUP=
LEGACY_BACKUP=
LEGACY=0
LOCK_HELD=0

collect_state() {
  SIZE=0
  SHA=
  MTIME=0
  DEX_EXISTS=0
  if [ -f "$DEX" ]; then
    DEX_EXISTS=1
    _size=$(file_size "$DEX")
    case "$_size" in
      ''|*[!0-9]*) SIZE=0 ;;
      *) SIZE=$_size ;;
    esac
    SHA=$(sha256_of "$DEX")
    _mtime=$(stat -c %Y "$DEX" 2>/dev/null)
    case "$_mtime" in
      ''|*[!0-9]*) MTIME=0 ;;
      *) MTIME=$_mtime ;;
    esac
  fi
  SI_VERSION=$(target_version)
  SI_VERSION_CODE=$(target_version_code)
  SI_MATCH=0
  if [ "$DEX_EXISTS" = 1 ] && version_ok; then SI_MATCH=1; fi
  BACKUP_COUNT=$(count_backups)
  BACKUP_OK=0
  if [ -n "$(find_original_backup)" ]; then BACKUP_OK=1; fi
  if [ -f "$PROMPT_FILE" ]; then PROMPTED=1; else PROMPTED=0; fi
  PENDING_REBOOT=0
  if [ -f "$PENDING_FILE" ]; then
    _cur_boot=$(current_boot_id)
    _pending_boot=$(sed -n '1p' "$PENDING_FILE" 2>/dev/null)
    if [ -n "$_cur_boot" ] && [ "$_pending_boot" = "$_cur_boot" ]; then
      PENDING_REBOOT=1
    else
      # 已经重启（启动标识变化）或读不到当前标识：清掉旧标记。
      rm -f "$PENDING_FILE" 2>/dev/null
    fi
  fi

  LEGACY=0
  if [ "$SDK" != 37 ]; then
    STATE=unsupported
  elif [ "$DEX_EXISTS" != 1 ]; then
    STATE=no-target
  elif [ "$SHA" = "$ORIGINAL_SHA" ] && [ "$SIZE" = "$ORIGINAL_SIZE" ]; then
    STATE=original
  elif [ "$SHA" = "$PATCH_SHA" ] && [ "$SIZE" = "$PATCH_SIZE" ]; then
    STATE=patched
  elif [ "$SHA" = "$LEGACY_PATCH_SHA" ] && [ "$SIZE" = "$LEGACY_PATCH_SIZE" ]; then
    STATE=patched-legacy
    LEGACY=1
  else
    STATE=unknown
  fi
}

print_check() {
  printf 'STATE=%s\n' "$STATE"
  printf 'SDK=%s\n' "$SDK"
  printf 'SI_VERSION=%s\n' "${SI_VERSION:-}"
  printf 'SI_VERSION_CODE=%s\n' "${SI_VERSION_CODE:-}"
  printf 'SI_TARGET_MODULE=%s\n' "$PATCH_FOR_MODULE"
  printf 'SI_TARGET_VERSION=%s\n' "${PATCH_FOR_VERSION:-}"
  printf 'SI_TARGET_VERSION_CODE=%s\n' "${PATCH_FOR_VERSION_CODE:-}"
  printf 'SI_TARGET_FILE=%s\n' "$TARGET"
  printf 'SI_MATCH=%s\n' "$SI_MATCH"
  printf 'DEX=%s\n' "$DEX"
  printf 'SIZE=%s\n' "$SIZE"
  printf 'MTIME=%s\n' "$MTIME"
  printf 'SHA=%s\n' "${SHA:-}"
  printf 'ORIGINAL_SIZE=%s\n' "$ORIGINAL_SIZE"
  printf 'ORIGINAL_SHA=%s\n' "$ORIGINAL_SHA"
  printf 'PATCH_SIZE=%s\n' "$PATCH_SIZE"
  printf 'PATCH_SHA=%s\n' "$PATCH_SHA"
  printf 'LEGACY=%s\n' "$LEGACY"
  printf 'BACKUP_COUNT=%s\n' "$BACKUP_COUNT"
  printf 'BACKUP_OK=%s\n' "$BACKUP_OK"
  printf 'PROMPTED=%s\n' "$PROMPTED"
  printf 'PENDING_REBOOT=%s\n' "$PENDING_REBOOT"
}

status_line() {
  case "$STATE" in
    unsupported)
      printf 'main.dex 补丁：不适用（Android SDK %s，仅支持 SDK 37）\n' "$SDK" ;;
    no-target)
      printf 'main.dex 补丁：未检测到 zygisk-storage-isolation 的 %s（%s）\n' "$TARGET" "$DEX" ;;
    original)
      if [ "$SI_MATCH" = 1 ]; then
        printf 'main.dex 补丁：可应用（zygisk-storage-isolation %s，原版 %s）\n' \
          "${SI_VERSION:-版本未知}" "$TARGET"
      else
        printf 'main.dex 补丁：不适用（当前 zygisk-storage-isolation %s，仅适用于 %s / %s）\n' \
          "${SI_VERSION:-版本未知}" "${PATCH_FOR_VERSION:-未知版本}" "$TARGET"
      fi ;;
    patched)
      if [ "$BACKUP_OK" = 1 ]; then
        printf 'main.dex 补丁：已应用（重启手机生效；可恢复原版）\n'
      else
        printf 'main.dex 补丁：已应用（重启手机生效；没有可用的原版备份）\n'
      fi ;;
    patched-legacy)
      if [ "$BACKUP_OK" = 1 ]; then
        printf 'main.dex 补丁：旧版社区补丁（可升级到自建版，或恢复原版）\n'
      else
        printf 'main.dex 补丁：旧版社区补丁（缺少原版备份，可先升级到自建版）\n'
      fi ;;
    *)
      if [ "$BACKUP_OK" = 1 ]; then
        printf 'main.dex 补丁：版本/哈希不匹配，未动（有可用的原版备份，可强制恢复）\n'
      else
        printf 'main.dex 补丁：版本/哈希不匹配，未动（sha256 %s）\n' "${SHA:-读取失败}"
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
    if [ -n "$_lp" ] && kill -0 "$_lp" 2>/dev/null; then
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

# 把 $1 复制到目标 dex：临时文件里 chown/chmod、校验 $2/$3，再原子替换。
install_file() {
  _src=$1
  _want=$2
  _want_size=$3
  _tmp=$TARGET_DIR/.$TARGET.new.$$
  TMP_TARGET=$_tmp
  if ! "$CP" "$_src" "$_tmp"; then
    rm -f "$_tmp" 2>/dev/null
    TMP_TARGET=
    return 1
  fi
  # 真机为 root；测试可用 SI_PATCH_CHOWN 注入可记录的命令，CI 非 root 也能覆盖这一步。
  if [ "$SI_TEST" = 1 ] && [ -n "${SI_PATCH_CHOWN:-}" ]; then
    if ! "$CHOWN" root:root "$_tmp" 2>/dev/null; then
      rm -f "$_tmp" 2>/dev/null
      TMP_TARGET=
      return 1
    fi
  elif [ "$(id -u 2>/dev/null)" = 0 ]; then
    if ! "$CHOWN" root:root "$_tmp" 2>/dev/null; then
      rm -f "$_tmp" 2>/dev/null
      TMP_TARGET=
      return 1
    fi
  fi
  if ! chmod 644 "$_tmp" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null
    TMP_TARGET=
    return 1
  fi
  _got=$(sha256_of "$_tmp")
  _gsize=$(file_size "$_tmp")
  if [ "$_got" != "$_want" ] || [ "$_gsize" != "$_want_size" ]; then
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
  _gsize=$(file_size "$DEX")
  [ "$_got" = "$_want" ] && [ "$_gsize" = "$_want_size" ]
}

create_backup() {
  mkdir -p "$BACKUP_DIR" 2>/dev/null || die "无法创建备份目录 $BACKUP_DIR" 5
  chmod 700 "$BACKUP_DIR" 2>/dev/null
  _ts=$(date '+%Y%m%d-%H%M%S' 2>/dev/null)
  [ -n "$_ts" ] || _ts=$(date +%s 2>/dev/null)
  _tmp=$BACKUP_DIR/.$TARGET.$_ts.tmp.$$
  BACKUP=$BACKUP_DIR/$TARGET.$_ts
  _n=0
  while [ -e "$BACKUP" ]; do
    _n=$((_n + 1))
    BACKUP=$BACKUP_DIR/$TARGET.$_ts.$(printf '%03d' "$_n")
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
  _gsize=$(file_size "$_tmp")
  if [ "$_got" != "$ORIGINAL_SHA" ] || [ "$_gsize" != "$ORIGINAL_SIZE" ]; then
    rm -f "$_tmp" 2>/dev/null
    die "备份校验失败（sha256=${_got:-读取失败}），未改动目标" 5
  fi
  if ! mv -f "$_tmp" "$BACKUP" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null
    die "备份落盘失败" 5
  fi
}

create_legacy_backup() {
  mkdir -p "$BACKUP_DIR" 2>/dev/null || die "无法创建备份目录 $BACKUP_DIR" 5
  chmod 700 "$BACKUP_DIR" 2>/dev/null
  _ts=$(date '+%Y%m%d-%H%M%S' 2>/dev/null)
  [ -n "$_ts" ] || _ts=$(date +%s 2>/dev/null)
  _tmp=$BACKUP_DIR/.$TARGET.legacy.$_ts.tmp.$$
  LEGACY_BACKUP=$BACKUP_DIR/$TARGET.legacy.$_ts
  _n=0
  while [ -e "$LEGACY_BACKUP" ]; do
    _n=$((_n + 1))
    LEGACY_BACKUP=$BACKUP_DIR/$TARGET.legacy.$_ts.$(printf '%03d' "$_n")
  done
  if ! "$CP" "$DEX" "$_tmp"; then
    rm -f "$_tmp" 2>/dev/null
    die "备份社区版 main.dex 失败" 5
  fi
  if ! chmod 600 "$_tmp" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null
    die "设置社区版备份权限失败" 5
  fi
  _got=$(sha256_of "$_tmp")
  _gsize=$(file_size "$_tmp")
  if [ "$_got" != "$LEGACY_PATCH_SHA" ] || [ "$_gsize" != "$LEGACY_PATCH_SIZE" ]; then
    rm -f "$_tmp" 2>/dev/null
    die "社区版备份校验失败（sha256=${_got:-读取失败}），未改动目标" 5
  fi
  if ! mv -f "$_tmp" "$LEGACY_BACKUP" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null
    die "社区版备份落盘失败" 5
  fi
}

do_apply() {
  collect_state
  case "$STATE" in
    patched)
      printf 'main.dex 补丁已应用，无需重复操作（恢复原版请用 restore）。\n'
      return 0 ;;
    unsupported)
      die "仅支持 Android 17（SDK 37），当前 SDK=${SDK}" 2 ;;
    no-target)
      die "找不到 $DEX，未检测到 zygisk-storage-isolation 模块" 2 ;;
    unknown)
      die "当前 $TARGET 的 sha256/大小既不是原版也不是补丁版（${SHA:-读取失败}），已拒绝操作；如果当前是旧版本补丁，请先运行 restore --force 再 apply" 3 ;;
    original|patched-legacy) ;;
    *) die "补丁状态异常（$STATE），已取消" 4 ;;
  esac
  if [ "$SI_MATCH" != 1 ]; then
    die "zygisk-storage-isolation 版本不适用（当前 ${SI_VERSION:-版本未知}/${SI_VERSION_CODE:-?}，仅适用于 ${PATCH_FOR_VERSION:-未知版本}/${PATCH_FOR_VERSION_CODE:-?} / $TARGET），未改动目标" 2
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
      printf 'main.dex 补丁已应用，无需重复操作（恢复原版请用 restore）。\n'
      return 0 ;;
    original) ;;
    patched-legacy) ;;
    no-target) die "锁定时目标消失：$DEX" 2 ;;
    unknown) die "锁定后目标哈希变化（${SHA:-读取失败}），已取消" 3 ;;
    *) die "锁定后状态异常：$STATE" 4 ;;
  esac
  if [ "$SI_MATCH" != 1 ]; then
    die "锁定后 zygisk-storage-isolation 版本不适用（当前 ${SI_VERSION:-版本未知}），已取消" 2
  fi
  _from_legacy=0
  [ "$STATE" = patched-legacy ] && _from_legacy=1

  [ -f "$ASSET" ] || die "模块缺少补丁资产 $ASSET" 5
  _asha=$(sha256_of "$ASSET")
  _asize=$(file_size "$ASSET")
  [ "$_asha" = "$PATCH_SHA" ] && [ "$_asize" = "$PATCH_SIZE" ] \
    || die "补丁资产校验失败（sha256=${_asha:-读取失败}，大小=${_asize:-读取失败}），未改动目标" 5

  if [ "$_from_legacy" = 1 ]; then
    create_legacy_backup
  else
    create_backup
  fi
  if ! install_file "$ASSET" "$PATCH_SHA" "$PATCH_SIZE"; then
    if [ "$_from_legacy" = 1 ] && [ -f "$LEGACY_BACKUP" ] \
       && install_file "$LEGACY_BACKUP" "$LEGACY_PATCH_SHA" "$LEGACY_PATCH_SIZE"; then
      log_action "APPLY-FAILED target=$TARGET from=legacy rollback=ok backup=$LEGACY_BACKUP"
      die "写入自建补丁失败，已回滚到社区版（备份：$LEGACY_BACKUP）" 5
    fi
    if [ "$_from_legacy" != 1 ] && [ -f "$BACKUP" ] \
       && install_file "$BACKUP" "$ORIGINAL_SHA" "$ORIGINAL_SIZE"; then
      log_action "APPLY-FAILED target=$TARGET rollback=ok backup=$BACKUP"
      die "写入补丁失败，已自动回滚到原版（备份：$BACKUP）" 5
    fi
    _bk=$BACKUP
    [ "$_from_legacy" = 1 ] && _bk=$LEGACY_BACKUP
    log_action "APPLY-FAILED target=$TARGET from=legacy=$_from_legacy rollback=failed backup=$_bk"
    die "写入补丁失败，且自动回滚失败；请用 restore 或手动从 $_bk 恢复" 6
  fi
  if [ "$_from_legacy" = 1 ]; then
    log_action "APPLY-LEGACY target=$TARGET from=$LEGACY_PATCH_SHA to=$PATCH_SHA backup=$LEGACY_BACKUP"
    printf '已从社区版升级到自建补丁：%s\n' "$DEX"
  else
    log_action "APPLY target=$TARGET original=$ORIGINAL_SHA patched=$PATCH_SHA backup=$BACKUP"
    printf '已应用补丁：%s\n' "$DEX"
  fi
  mark_pending_reboot || log_action "PENDING-FAILED target=$TARGET"
  printf '重启生效（Zygisk 模块在开机时加载）。\n'
}

do_restore() {
  collect_state
  if [ "$DEX_EXISTS" != 1 ]; then
    die "找不到 $DEX，无法恢复" 2
  fi
  if [ "$SHA" = "$ORIGINAL_SHA" ] && [ "$SIZE" = "$ORIGINAL_SIZE" ]; then
    die "当前已经是原版，无需恢复" 2
  fi
  if [ "$SI_MATCH" != 1 ]; then
    die "zygisk-storage-isolation 版本不匹配（当前 ${SI_VERSION:-版本未知}/${SI_VERSION_CODE:-?}，仅适用于 ${PATCH_FOR_VERSION:-未知版本}/${PATCH_FOR_VERSION_CODE:-?}），已拒绝恢复；版本不匹配时不能用原版备份覆盖" 2
  fi
  _is_legacy=0
  [ "$STATE" = patched-legacy ] && _is_legacy=1
  _backup=$(find_original_backup)
  if [ -z "$_backup" ]; then
    if [ "$_is_legacy" = 1 ]; then
      die "缺少原版备份，可先升级到自建版" 5
    fi
    die "没有可用的原版备份（$BACKUP_DIR），无法恢复" 5
  fi
  if [ "$SHA" != "$PATCH_SHA" ] && [ "$_is_legacy" != 1 ] && [ "$FORCE" != 1 ]; then
    die "当前 $TARGET 不是已知补丁版（${SHA:-读取失败}）；如确认要用原版备份覆盖，请加 --force" 3
  fi

  acquire_lock
  collect_state
  if [ "$SHA" = "$ORIGINAL_SHA" ] && [ "$SIZE" = "$ORIGINAL_SIZE" ]; then
    die "补丁状态已变化：当前已经是原版，已取消恢复" 4
  fi
  _is_legacy=0
  [ "$STATE" = patched-legacy ] && _is_legacy=1
  if [ "$SHA" != "$PATCH_SHA" ] && [ "$_is_legacy" != 1 ] && [ "$FORCE" != 1 ]; then
    die "补丁状态已变化（${SHA:-读取失败}），已取消恢复" 4
  fi
  _backup=$(find_original_backup)
  if [ -z "$_backup" ]; then
    if [ "$_is_legacy" = 1 ]; then
      die "缺少原版备份，可先升级到自建版" 5
    fi
    die "没有可用的原版备份（$BACKUP_DIR），已取消恢复" 5
  fi
  _bsha=$(sha256_of "$_backup")
  _bsize=$(file_size "$_backup")
  if [ "$_bsha" != "$ORIGINAL_SHA" ] || [ "$_bsize" != "$ORIGINAL_SIZE" ]; then
    die "选中的备份不是原版（sha256=${_bsha:-读取失败}），已拒绝恢复" 5
  fi

  # 先把操作前的目标留一份，恢复过程中失败可以退回去。
  _cur_sha=$SHA
  _cur_size=$SIZE
  if [ -z "$_cur_sha" ]; then
    die "当前目标 sha256 读取失败，已取消恢复" 3
  fi
  TMP_CUR=$TARGET_DIR/.$TARGET.cur.$$
  if ! "$CP" "$DEX" "$TMP_CUR"; then
    rm -f "$TMP_CUR" 2>/dev/null
    TMP_CUR=
    die "保存当前目标副本失败，未改动目标" 5
  fi
  if ! chmod 600 "$TMP_CUR" 2>/dev/null; then
    rm -f "$TMP_CUR" 2>/dev/null
    TMP_CUR=
    die "设置当前目标副本权限失败，未改动目标" 5
  fi
  _csha=$(sha256_of "$TMP_CUR")
  _csize=$(file_size "$TMP_CUR")
  if [ "$_csha" != "$_cur_sha" ] || [ "$_csize" != "$_cur_size" ]; then
    rm -f "$TMP_CUR" 2>/dev/null
    TMP_CUR=
    die "当前目标副本校验失败（sha256=${_csha:-读取失败}），未改动目标" 5
  fi

  if ! install_file "$_backup" "$ORIGINAL_SHA" "$ORIGINAL_SIZE"; then
    if install_file "$TMP_CUR" "$_cur_sha" "$_cur_size"; then
      log_action "RESTORE-FAILED target=$TARGET rollback=ok backup=$_backup"
      die "恢复原版失败，已回到操作前状态（备份：$_backup）" 5
    fi
    log_action "RESTORE-FAILED target=$TARGET rollback=failed backup=$_backup"
    # 回滚失败时保留操作前副本，别让 EXIT 清理把它删掉。
    _keep=$TMP_CUR
    TMP_CUR=
    die "恢复原版失败，且回滚失败；操作前副本保留在 $_keep" 6
  fi
  rm -f "$TMP_CUR" 2>/dev/null
  TMP_CUR=
  if [ "$_is_legacy" = 1 ]; then
    log_action "RESTORE-LEGACY original=$ORIGINAL_SHA backup=$_backup from=$_cur_sha"
  elif [ "$FORCE" = 1 ] && [ "$_cur_sha" != "$PATCH_SHA" ]; then
    log_action "RESTORE-FORCE original=$ORIGINAL_SHA backup=$_backup from=$_cur_sha"
  else
    log_action "RESTORE original=$ORIGINAL_SHA backup=$_backup"
  fi
  clear_pending_reboot
  printf '已恢复原版：%s\n' "$DEX"
  printf '重启生效（Zygisk 模块在开机时加载）。\n'
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
