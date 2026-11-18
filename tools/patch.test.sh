#!/system/bin/sh
# si-patch.sh / WebUI / uninstall 的 main.dex 补丁回归：
#   check 的 original/patched/patched-legacy/unknown/no-target、SDK 门禁、版本门禁、asset 哈希/大小、
#   备份创建/恢复/强制恢复、已 patched no-op、apply 失败回滚、restore 无备份报错、
#   目标 644 / 备份 600 / chown、持锁重查、并发锁；U1 卸载保留 patch-backup、
#   U2 restore/--force 版本门禁；legacy 识别/升级/恢复；静态断言 UI 后台/缓存/独立 busy/按钮归一化。
#   另外断言：补丁 check 不扫 /proc、不重启 server；WebUI 无 SERVER_PIDS/二次 check。
#   fake 模块目录 + SI_TEST 钩子；补丁资产用仓库里的真实 assets/main.dex。
#
# 用法：sh tools/patch.test.sh
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1
PATCH=scripts/si-patch.sh
ASSET_REAL=$PWD/assets/main.dex
TEST_SH=${SI_TEST_SH:-/system/bin/sh}
if ! { command -v "$TEST_SH" >/dev/null 2>&1 && "$TEST_SH" -c ':' >/dev/null 2>&1; }; then
  TEST_SH=$(command -v mksh 2>/dev/null)
fi
if [ -z "$TEST_SH" ] || ! { command -v "$TEST_SH" >/dev/null 2>&1 && "$TEST_SH" -c ':' >/dev/null 2>&1; }; then
  TEST_SH=$(command -v sh 2>/dev/null)
fi
if [ -z "$TEST_SH" ] || ! { command -v "$TEST_SH" >/dev/null 2>&1 && "$TEST_SH" -c ':' >/dev/null 2>&1; }; then
  echo "找不到可用的 sh（可用 SI_TEST_SH=... 指定）"; exit 1
fi

T=${TMPDIR:-/tmp}/si-patch-main-test.$$
DATA=$T/data
TARGET_DIR=$T/module
HOLDER=
cleanup() {
  [ -n "$HOLDER" ] && kill -9 "$HOLDER" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT INT TERM HUP
mkdir -p "$DATA" "$TARGET_DIR" "$T/fakebin" "$T/holder" || exit 1

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
size_of() { wc -c < "$1" 2>/dev/null | tr -d '[:space:]'; }

ASSET_SHA=$(sha_of "$ASSET_REAL")
PATCH_SHA_EXPECT=5413a01b6c49f360f3851af60be8820fcb8a4595d0c15697fcebac88b6d73891
ORIGINAL_SHA_EXPECT=a407674bba778267bac3d50bbdf528fa72fc219f46ef0463ad91bc58a56e82b9
PATCH_SIZE_EXPECT=88336
ORIGINAL_SIZE_EXPECT=90740

# ---------- 0) 仓库资产 / module.prop / 版本 ----------
[ -f "$ASSET_REAL" ] && ok "补丁资产存在" || bad "补丁资产不存在：$ASSET_REAL"
[ "$ASSET_SHA" = "$PATCH_SHA_EXPECT" ] && ok "补丁资产 sha256 正确" \
  || bad "补丁资产 sha256 不对：$ASSET_SHA"
[ "$(size_of "$ASSET_REAL")" = "$PATCH_SIZE_EXPECT" ] && ok "补丁资产大小 88336 B" \
  || bad "补丁资产大小不对：$(size_of "$ASSET_REAL")"
extra_asset=0
for _f in assets/*; do
  [ "$_f" = "assets/main.dex" ] || extra_asset=1
done
[ "$extra_asset" = 0 ] && ok "assets 只有 main.dex（没有 server-v355.dex）" \
  || bad "assets 里混入了其它文件"
grep -q "ORIGINAL_SHA=$ORIGINAL_SHA_EXPECT" "$PATCH" \
  && ok "脚本原版 sha256 常量正确" || bad "脚本原版 sha256 常量不对"
grep -q "ORIGINAL_SIZE=$ORIGINAL_SIZE_EXPECT" "$PATCH" \
  && ok "脚本原版大小常量正确" || bad "脚本原版大小常量不对"
grep -q "PATCH_SHA=$PATCH_SHA_EXPECT" "$PATCH" \
  && ok "脚本补丁 sha256 常量正确" || bad "脚本补丁 sha256 常量不对"
grep -q "PATCH_SIZE=$PATCH_SIZE_EXPECT" "$PATCH" \
  && ok "脚本补丁大小常量正确" || bad "脚本补丁大小常量不对"
grep -q '^LEGACY_PATCH_SHA=6d4058bc1c66fc14dec2331a603404a59c271d8a4b8f63c5270ff7029a8b80a7$' "$PATCH" \
  && ok "脚本识别社区旧补丁 sha" || bad "脚本缺少 LEGACY_PATCH_SHA"
grep -q '^LEGACY_PATCH_SIZE=99104$' "$PATCH" \
  && ok "脚本识别社区旧补丁大小" || bad "脚本缺少 LEGACY_PATCH_SIZE"
grep -q '^version=v1.5.6$' module.prop && grep -q '^versionCode=156$' module.prop \
  && ok "module.prop 版本 v1.5.6 / 156" || bad "module.prop 版本不对"
grep -q '^siPatchModule=zygisk-storage-isolation$' module.prop \
  && ok "module.prop 提供 siPatchModule" || bad "module.prop 缺少 siPatchModule"
grep -q '^siPatchTarget=main.dex$' module.prop \
  && ok "module.prop 提供 siPatchTarget=main.dex" || bad "module.prop 缺少 siPatchTarget"
grep -q '^siPatchVersion=v29.0.1$' module.prop && grep -q '^siPatchVersionCode=89$' module.prop \
  && ok "module.prop 提供模块版本 v29.0.1/89" || bad "module.prop 缺少模块版本字段"
! grep -q '^siPatchServer=' module.prop && ok "module.prop 去掉 siPatchServer" \
  || bad "module.prop 仍有 siPatchServer"
grep -q '"version": "v1.5.6"' update.json && grep -q '"versionCode": 156' update.json \
  && ok "update.json 指向 v1.5.6/156" || bad "update.json 版本不对"

# check 不能有进程扫描或 server 重启代码。
if grep -q '/proc/' "$PATCH"; then bad "si-patch.sh 仍引用 /proc（check 不应扫进程）"; else
  ok "si-patch.sh 不引用 /proc"
fi
for _n in SERVER_PIDS restart_si_server SERVER-RESTART TERM_WAIT RESTART_WAIT           find_dex_pids maps_has_dex count_dex_pids; do
  if grep -q "$_n" "$PATCH"; then bad "si-patch.sh 仍含 server 逻辑：$_n"; fi
done
for _n in '-TERM' '-KILL'; do
  if grep -q -- "$_n" "$PATCH"; then bad "si-patch.sh 仍含杀进程参数：$_n"; fi
done
if grep -q 'kill -0' "$PATCH"; then
  ok "锁检查只使用 kill -0（不杀进程）"
else
  bad "锁检查没有使用 kill -0"
fi
ok "si-patch.sh 没有 server 重启/等待逻辑"
if grep -q 'server-v355' "$PATCH"; then bad "si-patch.sh 仍引用 server-v355"; else
  ok "si-patch.sh 不再引用 server-v355"
fi

# ---------- fixture 与运行钩子 ----------
printf 'fake original main.dex fixture\n' > "$T/original.bin"
ORIG_SHA=$(sha_of "$T/original.bin")
ORIG_SIZE=$(size_of "$T/original.bin")
printf 'fake legacy community main.dex fixture\n' > "$T/legacy.bin"
LEGACY_SHA=$(sha_of "$T/legacy.bin")
LEGACY_SIZE=$(size_of "$T/legacy.bin")
SDK=37
CP_OVERRIDE=
ASSET_OVERRIDE=$ASSET_REAL
CHOWN_OVERRIDE=
PRELOCK_SLEEP=
PRELOCK_MARK=
CORRUPT_MARK=
OUT=
ERR=
RC=0

write_prop() {   # $1=version $2=versionCode；省略写 v29.0.1/89
  if [ "$#" -ge 1 ]; then _v=$1; else _v=v29.0.1; fi
  if [ "$#" -ge 2 ]; then _c=$2; else _c=89; fi
  printf 'id=zygisk-storage-isolation\nname=Zygisk - Enhanced mode for Storage Isolation\nversion=%s\nversionCode=%s\n' \
    "$_v" "$_c" > "$TARGET_DIR/module.prop"
}

run_patch() {
  SI_TEST=1 SI_PATCH_DATA=$DATA SI_PATCH_TARGET_DIR=$TARGET_DIR \
    SI_PATCH_ASSET=$ASSET_OVERRIDE SI_PATCH_SDK=$SDK \
    SI_PATCH_ORIGINAL_SHA=$ORIG_SHA SI_PATCH_ORIGINAL_SIZE=$ORIG_SIZE \
    SI_PATCH_LEGACY_SHA=$LEGACY_SHA SI_PATCH_LEGACY_SIZE=$LEGACY_SIZE \
    SI_PATCH_CP=$CP_OVERRIDE SI_PATCH_CHOWN=$CHOWN_OVERRIDE \
    SI_PATCH_PRELOCK_SLEEP=$PRELOCK_SLEEP SI_PATCH_PRELOCK_MARK=$PRELOCK_MARK \
    SI_PATCH_CORRUPT_AFTER_MV=$CORRUPT_MARK \
    "$TEST_SH" "$PATCH" "$@"
}

run_capture() {
  run_patch "$@" >"$T/out" 2>"$T/err"
  RC=$?
  OUT=$(cat "$T/out" 2>/dev/null)
  ERR=$(cat "$T/err" 2>/dev/null)
}

run_capture_umask() {
  ( umask 022; run_patch "$@" ) >"$T/out" 2>"$T/err"
  RC=$?
  OUT=$(cat "$T/out" 2>/dev/null)
  ERR=$(cat "$T/err" 2>/dev/null)
}

kv() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }
target_sha() { sha_of "$TARGET_DIR/main.dex"; }
target_size() { size_of "$TARGET_DIR/main.dex"; }
reset_original() {
  cp "$T/original.bin" "$TARGET_DIR/main.dex" || exit 1
  chmod 600 "$TARGET_DIR/main.dex"
  write_prop
}
reset_patched() {
  cp "$ASSET_REAL" "$TARGET_DIR/main.dex" || exit 1
  chmod 644 "$TARGET_DIR/main.dex"
  write_prop
}
reset_legacy() {
  cp "$T/legacy.bin" "$TARGET_DIR/main.dex" || exit 1
  chmod 600 "$TARGET_DIR/main.dex"
  write_prop
}
reset_unknown() {
  printf 'unknown main.dex fixture\n' > "$TARGET_DIR/main.dex" || exit 1
  chmod 600 "$TARGET_DIR/main.dex"
  write_prop
}
backups() {
  [ -d "$DATA/patch-backup" ] || return 0
  for _b in "$DATA/patch-backup/main.dex".*; do
    [ -f "$_b" ] || continue
    case "${_b##*/}" in
      *".tmp."*) continue ;;
    esac
    printf '%s\n' "$_b"
  done
}
backup_count() { backups | wc -l | tr -d '[:space:]'; }
latest_backup() { backups | tail -1; }
clean_data() {
  rm -rf "$DATA/patch-backup" "$DATA/.si-patch.lock" 2>/dev/null
  rm -f "$DATA/patch.log" "$DATA/.patch_prompted" 2>/dev/null
  rm -f "$TARGET_DIR"/.main.dex.* 2>/dev/null
}
reset_hooks() {
  CP_OVERRIDE=
  ASSET_OVERRIDE=$ASSET_REAL
  CHOWN_OVERRIDE=
  PRELOCK_SLEEP=
  PRELOCK_MARK=
  CORRUPT_MARK=
  SDK=37
  write_prop
}

# ---------- 1) SDK≠37 ----------
reset_hooks
clean_data
reset_original
SDK=36
run_capture check
[ "$RC" = 0 ] && ok "check 在 SDK=36 返回 0" || bad "check 在 SDK=36 退出码 $RC"
[ "$(kv STATE)" = unsupported ] && ok "SDK=36 判为 unsupported" \
  || bad "SDK=36 状态不对：$(kv STATE)"
[ "$(kv SDK)" = 36 ] && ok "输出实际 SDK=36" || bad "输出 SDK 不对：$(kv SDK)"
[ "$(kv SHA)" = "$ORIG_SHA" ] && ok "unsupported 仍输出目标 sha" \
  || bad "unsupported 没输出目标 sha：$(kv SHA)"
run_capture status
has "$OUT" '不适用' && ok "status 说明不支持" || bad "status 没说明不支持：$OUT"
run_capture apply
[ "$RC" != 0 ] && ok "SDK=36 apply 拒绝" || bad "SDK=36 apply 没有拒绝"
has "$ERR" '仅支持 Android 17' && ok "SDK=36 拒绝原因明确" || bad "SDK=36 拒绝原因不清：$ERR"
[ "$(target_sha)" = "$ORIG_SHA" ] && ok "SDK=36 没动目标" || bad "SDK=36 改动了目标"

# ---------- 2) no-target ----------
reset_hooks
clean_data
rm -f "$TARGET_DIR/main.dex"
run_capture check
[ "$RC" = 0 ] && ok "check 在 no-target 返回 0" || bad "check 在 no-target 退出码 $RC"
[ "$(kv STATE)" = no-target ] && ok "缺 main.dex 判为 no-target" \
  || bad "缺 main.dex 状态不对：$(kv STATE)"
[ "$(kv SIZE)" = 0 ] && ok "no-target 的 SIZE=0" || bad "no-target 的 SIZE 不对：$(kv SIZE)"
[ -z "$(kv SHA)" ] && ok "no-target 的 SHA 为空" || bad "no-target 仍输出 SHA：$(kv SHA)"
run_capture status
has "$OUT" '未检测到' && ok "status 说明未检测到" || bad "status 没说明未检测到：$OUT"
run_capture apply
[ "$RC" != 0 ] && ok "no-target apply 拒绝" || bad "no-target apply 没有拒绝"
has "$ERR" '找不到' && ok "no-target 拒绝原因明确" || bad "no-target 拒绝原因不清：$ERR"
run_capture restore
[ "$RC" != 0 ] && ok "no-target restore 拒绝" || bad "no-target restore 没有拒绝"
has "$ERR" '找不到' && ok "no-target restore 原因明确" || bad "no-target restore 原因不清：$ERR"

# ---------- 3) original + 版本门禁 ----------
reset_hooks
clean_data
reset_original
run_capture check
[ "$RC" = 0 ] && ok "check 在 original 返回 0" || bad "check 在 original 退出码 $RC"
[ "$(kv STATE)" = original ] && ok "原版哈希/大小判为 original" \
  || bad "原版状态不对：$(kv STATE)"
[ "$(kv SI_MATCH)" = 1 ] && ok "模块版本匹配时 SI_MATCH=1" \
  || bad "SI_MATCH 不对：$(kv SI_MATCH)"
[ "$(kv SI_TARGET_MODULE)" = zygisk-storage-isolation ] && ok "输出目标模块" \
  || bad "目标模块字段不对：$(kv SI_TARGET_MODULE)"
[ "$(kv SI_TARGET_FILE)" = main.dex ] && ok "输出目标文件 main.dex" \
  || bad "目标文件字段不对：$(kv SI_TARGET_FILE)"
[ "$(kv SI_TARGET_VERSION)" = v29.0.1 ] && ok "输出适用模块版本" \
  || bad "适用版本字段不对：$(kv SI_TARGET_VERSION)"
[ "$(kv SI_TARGET_VERSION_CODE)" = 89 ] && ok "输出适用模块 versionCode" \
  || bad "适用 versionCode 字段不对：$(kv SI_TARGET_VERSION_CODE)"
[ "$(kv DEX)" = "$TARGET_DIR/main.dex" ] && ok "输出 main.dex 路径" \
  || bad "dex 路径不对：$(kv DEX)"
[ "$(kv SIZE)" = "$ORIG_SIZE" ] && ok "输出 dex 大小" \
  || bad "dex 大小不对：$(kv SIZE)"
[ "$(kv SHA)" = "$ORIG_SHA" ] && ok "输出 dex sha256" || bad "dex sha256 不对：$(kv SHA)"
case "$(kv MTIME)" in
  ''|*[!0-9]*) bad "MTIME 不是数字：$(kv MTIME)" ;;
  *) ok "输出 dex mtime（供 UI 缓存）" ;;
esac
[ "$(kv ORIGINAL_SIZE)" = "$ORIG_SIZE" ] && ok "输出原版大小常量" \
  || bad "原版大小字段不对：$(kv ORIGINAL_SIZE)"
[ "$(kv BACKUP_COUNT)" = 0 ] && ok "初始没有备份" \
  || bad "初始备份数不对：$(kv BACKUP_COUNT)"
[ "$(kv BACKUP_OK)" = 0 ] && ok "初始没有可用原版备份" \
  || bad "初始 BACKUP_OK 不对：$(kv BACKUP_OK)"
[ "$(kv PROMPTED)" = 0 ] && ok "初始未提示" || bad "初始 PROMPTED 不对：$(kv PROMPTED)"
[ "$(kv LEGACY)" = 0 ] && ok "原版 LEGACY=0" || bad "原版 LEGACY 不对：$(kv LEGACY)"
[ "$(printf '%s\n' "$OUT" | grep -c '^[A-Z_][A-Z_]*=')" = 21 ] \
  && ok "check 输出 21 个 KEY=VALUE" || bad "check 字段数不对"
has "$OUT" 'SERVER_PIDS=' && bad "check 仍输出 SERVER_PIDS" \
  || ok "check 不输出 SERVER_PIDS"
[ ! -f "$DATA/patch.log" ] && ok "check 不写 patch.log" || bad "check 写了 patch.log"
run_capture status
has "$OUT" '可应用' && ok "status 显示可应用" || bad "status 没显示可应用：$OUT"

: > "$DATA/.patch_prompted.main.dex.v29.0.1"
run_capture check
[ "$(kv PROMPTED)" = 1 ] && ok "存在按目标/版本区分的提示标记时 PROMPTED=1" \
  || bad "PROMPTED 没读标记：$(kv PROMPTED)"
: > "$DATA/.patch_prompted"
rm -f "$DATA/.patch_prompted.main.dex.v29.0.1"
run_capture check
[ "$(kv PROMPTED)" = 0 ] && ok "旧版单一 .patch_prompted 不再命中" \
  || bad "旧版提示标记仍被当成已提示：$(kv PROMPTED)"

write_prop v29.0.0 88
run_capture check
[ "$(kv SI_MATCH)" = 0 ] && ok "模块版本不匹配时 SI_MATCH=0" \
  || bad "版本不匹配 SI_MATCH 不对：$(kv SI_MATCH)"
run_capture status
has "$OUT" '不适用' && ok "status 显示版本不适用" || bad "status 没显示版本不适用：$OUT"
run_capture apply
[ "$RC" != 0 ] && ok "版本不匹配 apply 拒绝" || bad "版本不匹配 apply 没有拒绝"
has "$ERR" '版本不适用' && ok "版本不匹配原因明确" || bad "版本不匹配原因不清：$ERR"
[ "$(target_sha)" = "$ORIG_SHA" ] && ok "版本不匹配没动目标" || bad "版本不匹配改动了目标"
write_prop ''
run_capture check
[ "$(kv SI_MATCH)" = 1 ] && ok "模块版本读不到时按目标存在视为适用" \
  || bad "版本读不到时 SI_MATCH 不对：$(kv SI_MATCH)"
reset_hooks

# ---------- 3b) 社区旧补丁 legacy ----------
reset_hooks
clean_data
reset_legacy
run_capture check
[ "$(kv STATE)" = patched-legacy ] && ok "社区旧补丁判为 patched-legacy" \
  || bad "社区旧补丁状态不对：$(kv STATE)"
[ "$(kv LEGACY)" = 1 ] && ok "社区旧补丁 LEGACY=1" \
  || bad "社区旧补丁 LEGACY 不对：$(kv LEGACY)"
[ "$(kv SIZE)" = "$LEGACY_SIZE" ] && [ "$(kv SHA)" = "$LEGACY_SHA" ] \
  && ok "社区旧补丁输出实际大小/sha" || bad "社区旧补丁大小/sha 不对"
[ "$(kv BACKUP_OK)" = 0 ] && ok "社区旧补丁初始没有原版备份" \
  || bad "社区旧补丁初始 BACKUP_OK 不对：$(kv BACKUP_OK)"
run_capture status
has "$OUT" '旧版社区补丁' && ok "status 说明旧版社区补丁" \
  || bad "status 没说明旧版社区补丁：$OUT"
run_capture restore
[ "$RC" != 0 ] && ok "社区旧补丁无原版备份 restore 拒绝" \
  || bad "社区旧补丁无原版备份 restore 仍成功"
has "$ERR" '缺少原版备份，可先升级到自建版' && ok "无原版备份提示可先升级" \
  || bad "无原版备份提示不对：$ERR"
[ "$(target_sha)" = "$LEGACY_SHA" ] && ok "无原版备份拒绝后目标未动" \
  || bad "无原版备份拒绝后目标被改"
run_capture apply
[ "$RC" = 0 ] && ok "社区旧补丁允许升级到自建版" || bad "社区旧补丁升级失败（$RC）：$ERR"
has "$OUT" '已从社区版升级到自建补丁' && ok "升级输出说明从社区版升级" \
  || bad "升级输出文案不对：$OUT"
[ "$(target_sha)" = "$PATCH_SHA_EXPECT" ] && ok "升级后目标是自建补丁" \
  || bad "升级后目标不是自建补丁：$(target_sha)"
[ "$(backup_count)" = 1 ] && ok "升级时产生 1 份社区版备份" \
  || bad "升级后备份数不对：$(backup_count)"
_lb=$(latest_backup)
case "${_lb##*/}" in
  main.dex.legacy.*) ok "社区版备份名为 main.dex.legacy.<时间戳>" ;;
  *) bad "社区版备份名不对：$_lb" ;;
esac
[ -n "$_lb" ] && [ "$(sha_of "$_lb")" = "$LEGACY_SHA" ] \
  && ok "社区版备份内容是社区旧补丁" || bad "社区版备份内容不对：$_lb"
[ "$(stat -c %a "$_lb" 2>/dev/null)" = 600 ] && ok "社区版备份权限 600" \
  || bad "社区版备份权限不对：$(stat -c %a "$_lb" 2>/dev/null)"
run_capture check
[ "$(kv STATE)" = patched ] && [ "$(kv LEGACY)" = 0 ] \
  && ok "升级后 STATE=patched / LEGACY=0" \
  || bad "升级后状态不对：$(kv STATE)/$(kv LEGACY)"
[ "$(kv BACKUP_OK)" = 0 ] && ok "没有原版备份时 BACKUP_OK 仍为 0" \
  || bad "升级后 BACKUP_OK 不对：$(kv BACKUP_OK)"

# 社区旧补丁 → 原版（已有原版备份）
reset_hooks
clean_data
reset_original
run_capture apply
[ "$RC" = 0 ] && ok "为 legacy→原版用例准备原版备份和自建补丁" \
  || bad "legacy→原版用例准备失败：$ERR"
reset_legacy
run_capture check
[ "$(kv STATE)" = patched-legacy ] && [ "$(kv BACKUP_OK)" = 1 ] \
  && ok "社区旧补丁且有有效原版备份" \
  || bad "社区旧补丁备份状态不对：$(kv STATE)/$(kv BACKUP_OK)"
run_capture restore
[ "$RC" = 0 ] && ok "社区旧补丁可直接 restore" || bad "社区旧补丁 restore 失败（$RC）：$ERR"
[ "$(target_sha)" = "$ORIG_SHA" ] && ok "社区旧补丁恢复后回到原版" \
  || bad "社区旧补丁恢复后哈希不对"
run_capture check
[ "$(kv STATE)" = original ] && [ "$(kv LEGACY)" = 0 ] \
  && ok "legacy→原版后 STATE=original / LEGACY=0" \
  || bad "legacy→原版后状态不对：$(kv STATE)/$(kv LEGACY)"

# 社区旧补丁 → 自建版，保留原版备份
reset_hooks
clean_data
reset_original
run_capture apply
[ "$RC" = 0 ] && ok "为 legacy→自建用例准备原版备份" \
  || bad "legacy→自建用例准备失败：$ERR"
reset_legacy
run_capture apply
[ "$RC" = 0 ] && ok "已有原版备份时仍允许升级到自建版" \
  || bad "已有原版备份时升级失败（$RC）：$ERR"
[ "$(target_sha)" = "$PATCH_SHA_EXPECT" ] && ok "legacy→自建后目标是自建补丁" \
  || bad "legacy→自建后目标不对"
run_capture check
[ "$(kv STATE)" = patched ] && [ "$(kv BACKUP_OK)" = 1 ] && [ "$(kv BACKUP_COUNT)" = 2 ] \
  && ok "升级后保留原版备份（原版+legacy 共 2 份）" \
  || bad "升级后备份状态不对：$(kv STATE)/$(kv BACKUP_OK)/$(kv BACKUP_COUNT)"
reset_hooks
clean_data

# ---------- 4) unknown 拒绝 ----------
reset_hooks
clean_data
reset_unknown
reset_sha=$(target_sha)
run_capture check
[ "$(kv STATE)" = unknown ] && ok "未知哈希判为 unknown" \
  || bad "未知哈希状态不对：$(kv STATE)"
[ "$(kv BACKUP_OK)" = 0 ] && ok "未知哈希且无备份 BACKUP_OK=0" \
  || bad "unknown BACKUP_OK 不对：$(kv BACKUP_OK)"
run_capture status
has "$OUT" '版本/哈希不匹配' && ok "status 显示版本/哈希不匹配" \
  || bad "status 没显示版本/哈希不匹配：$OUT"
run_capture apply
[ "$RC" != 0 ] && ok "unknown apply 拒绝" || bad "unknown apply 没有拒绝"
has "$ERR" '已拒绝操作' && ok "unknown 拒绝原因明确" || bad "unknown 拒绝原因不清：$ERR"
has "$ERR" 'restore --force' && ok "unknown 提示先 restore --force" \
  || bad "unknown 没有提示 restore --force：$ERR"
[ "$(target_sha)" = "$reset_sha" ] && ok "unknown 没动目标" || bad "unknown 改动了目标"
run_capture restore
[ "$RC" != 0 ] && ok "unknown 且无备份 restore 拒绝" || bad "unknown restore 没有拒绝"
has "$ERR" '没有可用的原版备份' && ok "unknown 无备份原因明确" \
  || bad "unknown 无备份原因不清：$ERR"
[ ! -d "$DATA/.si-patch.lock" ] && ok "拒绝路径没有留下锁" \
  || bad "拒绝路径留下了锁目录"

# ---------- 5) asset 缺失 / 哈希不对 ----------
reset_hooks
clean_data
reset_original
ASSET_OVERRIDE=$T/missing.dex
run_capture apply
[ "$RC" != 0 ] && ok "asset 缺失 apply 失败" || bad "asset 缺失 apply 没失败"
has "$ERR" '缺少补丁资产' && ok "asset 缺失原因明确" || bad "asset 缺失原因不清：$ERR"
[ "$(target_sha)" = "$ORIG_SHA" ] && ok "asset 缺失没动目标" || bad "asset 缺失改动了目标"
[ "$(backup_count)" = 0 ] && ok "asset 缺失没有产生备份" \
  || bad "asset 缺失产生了备份：$(backup_count)"

printf 'not the patch\n' > "$T/bad-asset.dex"
ASSET_OVERRIDE=$T/bad-asset.dex
run_capture apply
[ "$RC" != 0 ] && ok "asset 哈希不对 apply 失败" || bad "asset 哈希不对 apply 没失败"
has "$ERR" '补丁资产校验失败' && ok "asset 哈希不对原因明确" \
  || bad "asset 哈希不对原因不清：$ERR"
[ "$(target_sha)" = "$ORIG_SHA" ] && ok "asset 哈希不对没动目标" \
  || bad "asset 哈希不对改动了目标"
[ "$(backup_count)" = 0 ] && ok "asset 哈希不对没有产生备份" \
  || bad "asset 哈希不对产生了备份：$(backup_count)"

# ---------- 6) 备份创建时的哈希校验 ----------
reset_hooks
clean_data
reset_original
cat > "$T/fakebin/cp-tmpfail" <<'S'
#!/bin/sh
last=
for a in "$@"; do last=$a; done
case "$last" in
  *".tmp."*)
    if [ ! -e "$0.once" ]; then
      : > "$0.once"
      printf 'corrupt backup\n' > "$last"
      exit 0
    fi ;;
esac
exec cp "$@"
S
chmod 755 "$T/fakebin/cp-tmpfail"
CP_OVERRIDE=$T/fakebin/cp-tmpfail
run_capture apply
[ "$RC" != 0 ] && ok "备份内容损坏 apply 失败" || bad "备份内容损坏 apply 没失败"
has "$ERR" '备份校验失败' && ok "备份创建哈希被校验" || bad "备份创建哈希没校验：$ERR"
[ "$(target_sha)" = "$ORIG_SHA" ] && ok "备份失败没动目标" || bad "备份失败改动了目标"
[ "$(backup_count)" = 0 ] && ok "备份失败没有留下成品备份" \
  || bad "备份失败留下了备份：$(backup_count)"

# ---------- 7) 复制失败回滚（mv 前） ----------
reset_hooks
clean_data
reset_original
cat > "$T/fakebin/cp-newfail" <<'S'
#!/bin/sh
last=
for a in "$@"; do last=$a; done
case "$last" in
  *".new."*)
    if [ ! -e "$0.once" ]; then
      : > "$0.once"
      exit 1
    fi ;;
esac
exec cp "$@"
S
chmod 755 "$T/fakebin/cp-newfail"
CP_OVERRIDE=$T/fakebin/cp-newfail
run_capture apply
[ "$RC" != 0 ] && ok "复制失败 apply 失败" || bad "复制失败 apply 没失败"
has "$ERR" '已自动回滚' && ok "复制失败自动回滚" || bad "复制失败没回滚：$ERR"
[ "$(target_sha)" = "$ORIG_SHA" ] && ok "回滚后目标仍是原版" || bad "回滚后目标不是原版"
[ "$(backup_count)" = 1 ] && ok "失败前已留下 1 份备份" \
  || bad "失败前备份数不对：$(backup_count)"
_bl=$(latest_backup)
[ -n "$_bl" ] && [ "$(sha_of "$_bl")" = "$ORIG_SHA" ] && ok "备份内容是原版" \
  || bad "备份内容不是原版：$_bl"

# ---------- 8) mv 后校验失败 → 真实回滚 ----------
reset_hooks
clean_data
reset_original
CORRUPT_MARK=$T/corrupt-apply
run_capture apply
[ "$RC" != 0 ] && ok "替换后哈希不符 apply 失败" || bad "替换后哈希不符 apply 没失败"
has "$ERR" '已自动回滚' && ok "替换后哈希不符触发回滚" || bad "替换后哈希不符没回滚：$ERR"
[ "$(target_sha)" = "$ORIG_SHA" ] && ok "真实回滚把目标恢复成原版" \
  || bad "真实回滚后目标不是原版：$(target_sha)"
grep -q 'APPLY-FAILED.*rollback=ok' "$DATA/patch.log" 2>/dev/null \
  && ok "回滚成功写入日志" || bad "回滚成功没有日志"

# ---------- 9) chown / 权限 / apply 成功 / no-op ----------
reset_hooks
clean_data
reset_original
cat > "$T/fakebin/chown" <<'S'
#!/bin/sh
printf '%s\n' "$*" >> "$0.log"
exit 0
S
chmod 755 "$T/fakebin/chown"
rm -f "$T/fakebin/chown.log"
CHOWN_OVERRIDE=$T/fakebin/chown
run_capture_umask apply
[ "$RC" = 0 ] && ok "umask 022 下 apply 成功" || bad "umask 022 下 apply 失败：$ERR"
[ "$(target_sha)" = "$PATCH_SHA_EXPECT" ] && ok "目标已换成补丁 main.dex" \
  || bad "目标哈希不是补丁：$(target_sha)"
[ "$(target_size)" = "$PATCH_SIZE_EXPECT" ] && ok "目标大小 88336 B" \
  || bad "目标大小不对：$(target_size)"
has "$OUT" '重启生效（Zygisk 模块在开机时加载）' && ok "apply 提示重启生效" \
  || bad "apply 没提示重启生效：$OUT"
! has "$OUT" 'server' && ok "apply 输出不再提 server" || bad "apply 输出仍提 server：$OUT"
[ -f "$T/fakebin/chown.log" ] && grep -q 'root:root' "$T/fakebin/chown.log" \
  && ok "apply 调用了 chown root:root" || bad "apply 没有调用 chown root:root"
[ "$(backup_count)" = 1 ] && ok "apply 留下 1 份备份" || bad "apply 备份数不对：$(backup_count)"
_bl=$(latest_backup)
case "${_bl##*/}" in main.dex.*) ok "备份文件名为 main.dex.<时间戳>" ;; *) bad "备份文件名不对：$_bl" ;; esac
[ -n "$_bl" ] && [ "$(sha_of "$_bl")" = "$ORIG_SHA" ] && ok "备份内容为原版" \
  || bad "备份内容不对：$_bl"
[ "$(stat -c %a "$TARGET_DIR/main.dex" 2>/dev/null)" = 644 ] && ok "目标权限 644" \
  || bad "目标权限不对：$(stat -c %a "$TARGET_DIR/main.dex" 2>/dev/null)"
[ "$(stat -c %a "$_bl" 2>/dev/null)" = 600 ] && ok "备份权限 600" \
  || bad "备份权限不对：$(stat -c %a "$_bl" 2>/dev/null)"
if [ "$(id -u 2>/dev/null)" = 0 ]; then
  [ "$(stat -c %U 2>/dev/null "$TARGET_DIR/main.dex")" = root ] && ok "目标属主 root" \
    || bad "目标属主不是 root"
fi
grep -q 'APPLY' "$DATA/patch.log" 2>/dev/null && ok "写了 apply 日志" \
  || bad "没有 apply 日志"
! grep -q 'SERVER-RESTART' "$DATA/patch.log" 2>/dev/null && ok "apply 没有 server 重启日志" \
  || bad "apply 仍写 server 重启日志"
run_capture check
[ "$(kv STATE)" = patched ] && ok "apply 后 check=patched" \
  || bad "apply 后状态不对：$(kv STATE)"
[ "$(kv BACKUP_COUNT)" = 1 ] && ok "check 报告 1 份备份" \
  || bad "check 备份数不对：$(kv BACKUP_COUNT)"
[ "$(kv BACKUP_OK)" = 1 ] && ok "check 报告有可用原版备份" \
  || bad "check BACKUP_OK 不对：$(kv BACKUP_OK)"
run_capture apply
[ "$RC" = 0 ] && ok "已 patched apply 返回成功" || bad "已 patched apply 失败（$RC）"
has "$OUT" '无需重复' && ok "已 patched 提示无需重复" || bad "已 patched 提示不对：$OUT"
[ "$(backup_count)" = 1 ] && ok "no-op 没有新增备份" || bad "no-op 新增了备份：$(backup_count)"
[ "$(target_sha)" = "$PATCH_SHA_EXPECT" ] && ok "no-op 没有改目标" || bad "no-op 改动了目标"
CHOWN_OVERRIDE=

# ---------- 10) restore：最新备份坏、旧备份有效 ----------
printf 'corrupt newest backup\n' > "$DATA/patch-backup/main.dex.99991231-235959"
chmod 600 "$DATA/patch-backup/main.dex.99991231-235959"
run_capture check
[ "$(kv BACKUP_COUNT)" = 2 ] && ok "最新坏备份计入总数" \
  || bad "备份总数不对：$(kv BACKUP_COUNT)"
[ "$(kv BACKUP_OK)" = 1 ] && ok "最新坏但旧的有效时 BACKUP_OK=1" \
  || bad "BACKUP_OK 没跳过坏备份：$(kv BACKUP_OK)"
run_capture restore
[ "$RC" = 0 ] && ok "最新备份坏时 restore 仍成功" || bad "restore 没选旧的有效备份（$RC）：$ERR"
[ "$(target_sha)" = "$ORIG_SHA" ] && ok "restore 回到原版" || bad "restore 后哈希不对"
has "$OUT" '重启生效（Zygisk 模块在开机时加载）' && ok "restore 提示重启生效" \
  || bad "restore 没提示重启生效：$OUT"

# ---------- 11) 备份全坏 ----------
run_capture apply
[ "$RC" = 0 ] && ok "为全坏备份用例重新应用" || bad "全坏备份用例准备失败：$ERR"
for _b in "$DATA/patch-backup/main.dex".*; do
  [ -f "$_b" ] || continue
  printf 'corrupt backup\n' > "$_b"
  chmod 600 "$_b"
done
run_capture check
[ "$(kv STATE)" = patched ] && [ "$(kv BACKUP_OK)" = 0 ] \
  && ok "备份全坏时 BACKUP_OK=0" || bad "备份全坏 check 不对：$(kv BACKUP_OK)"
run_capture restore
[ "$RC" != 0 ] && ok "备份全坏 restore 拒绝" || bad "备份全坏 restore 仍成功"
has "$ERR" '没有可用的原版备份' && ok "备份全坏原因明确" \
  || bad "备份全坏原因不清：$ERR"
[ "$(target_sha)" = "$PATCH_SHA_EXPECT" ] && ok "备份全坏失败时目标仍是补丁" \
  || bad "备份全坏失败时目标被改"

# ---------- 12) unknown + 有效备份 → 强制恢复 ----------
reset_hooks
clean_data
reset_original
run_capture apply
[ "$RC" = 0 ] && ok "为强制恢复用例准备补丁版" || bad "强制恢复用例准备失败：$ERR"
reset_unknown
run_capture check
[ "$(kv STATE)" = unknown ] && [ "$(kv BACKUP_OK)" = 1 ] \
  && ok "unknown 且存在有效原版备份" || bad "unknown 备份状态不对：$(kv STATE)/$(kv BACKUP_OK)"
run_capture status
has "$OUT" '可强制恢复' && ok "status 提示可强制恢复" || bad "status 没提示强制恢复：$OUT"
run_capture restore
[ "$RC" != 0 ] && ok "unknown 不带 --force 拒绝" || bad "unknown 不带 --force 仍恢复"
has "$ERR" '--force' && ok "提示需要 --force" || bad "没提示 --force：$ERR"
[ "$(target_sha)" != "$ORIG_SHA" ] && ok "未强制时没动目标" || bad "未强制时改动了目标"
run_capture restore --force
[ "$RC" = 0 ] && ok "unknown 强制恢复成功" || bad "强制恢复失败（$RC）：$ERR"
[ "$(target_sha)" = "$ORIG_SHA" ] && ok "强制恢复后回到原版" || bad "强制恢复后哈希不对"

# ---------- 12b) 版本不匹配时拒绝恢复/强制恢复 ----------
reset_hooks
clean_data
reset_original
run_capture apply
[ "$RC" = 0 ] && ok "为版本门禁用例准备补丁版和备份" || bad "版本门禁用例准备失败：$ERR"
write_prop v29.0.0 88
run_capture check
[ "$(kv STATE)" = patched ] && [ "$(kv SI_MATCH)" = 0 ] && [ "$(kv BACKUP_OK)" = 1 ] \
  && ok "版本不匹配但仍是 patched、有有效备份" \
  || bad "版本门禁用例状态不对：$(kv STATE)/$(kv SI_MATCH)/$(kv BACKUP_OK)"
run_capture restore
[ "$RC" != 0 ] && ok "版本不匹配时 restore 拒绝" || bad "版本不匹配 restore 仍成功"
has "$ERR" '版本不匹配' && ok "restore 报错提示版本不匹配" \
  || bad "restore 没提示版本不匹配：$ERR"
[ "$(target_sha)" = "$PATCH_SHA_EXPECT" ] && ok "版本不匹配 restore 没动目标" \
  || bad "版本不匹配 restore 动了目标"
run_capture restore --force
[ "$RC" != 0 ] && ok "版本不匹配时 restore --force 拒绝" \
  || bad "版本不匹配 restore --force 仍成功"
has "$ERR" '版本不匹配' && ok "强制恢复报错提示版本不匹配" \
  || bad "强制恢复没提示版本不匹配：$ERR"
[ "$(target_sha)" = "$PATCH_SHA_EXPECT" ] && ok "版本不匹配强制恢复没动目标" \
  || bad "版本不匹配强制恢复动了目标"
reset_hooks
clean_data

# ---------- 13) restore 当前副本与回滚 ----------
reset_hooks
clean_data
reset_original
run_capture apply
[ "$RC" = 0 ] && ok "为 restore 回滚用例准备补丁版" || bad "restore 回滚用例准备失败：$ERR"
CORRUPT_MARK=$T/corrupt-restore
run_capture restore
[ "$RC" != 0 ] && ok "restore 替换后校验失败" || bad "restore 替换后校验没失败"
has "$ERR" '已回到操作前状态' && ok "restore 失败回滚到补丁版" \
  || bad "restore 失败没回滚：$ERR"
[ "$(target_sha)" = "$PATCH_SHA_EXPECT" ] && ok "restore 回滚后仍是补丁版" \
  || bad "restore 回滚后目标不对"

# ---------- 14) 已是原版 / 没有备份 ----------
reset_hooks
clean_data
reset_original
run_capture restore
[ "$RC" != 0 ] && ok "已是原版时 restore 报错" || bad "已是原版 restore 仍成功"
has "$ERR" '已经是原版' && ok "已是原版报错原因明确" || bad "已是原版报错原因不清：$ERR"

run_capture apply
[ "$RC" = 0 ] && ok "为无备份用例重新应用" || bad "无备份用例准备失败：$ERR"
rm -rf "$DATA/patch-backup"
run_capture restore
[ "$RC" != 0 ] && ok "没有备份时 restore 报错" || bad "没有备份 restore 仍成功"
has "$ERR" '没有可用的原版备份' && ok "无备份报错原因明确" \
  || bad "无备份报错原因不清：$ERR"
[ "$(target_sha)" = "$PATCH_SHA_EXPECT" ] && ok "无备份失败时目标仍是补丁" \
  || bad "无备份失败时目标被改"

# ---------- 15) 持锁后重查 ----------
reset_hooks
clean_data
reset_original
rm -f "$T/prelock.mark"
PRELOCK_SLEEP=2
PRELOCK_MARK=$T/prelock.mark
( run_patch apply >"$T/bg.out" 2>"$T/bg.err"; echo $? >"$T/bg.rc" ) &
_bg=$!
_i=0
while [ ! -e "$T/prelock.mark" ] && [ "$_i" -lt 40 ]; do
  sleep 0.1
  _i=$((_i + 1))
done
if [ -e "$T/prelock.mark" ]; then
  ok "apply 在拿锁前进入测试窗口"
else
  bad "apply 没有进入拿锁前测试窗口"
fi
cp "$ASSET_REAL" "$TARGET_DIR/main.dex"
chmod 644 "$TARGET_DIR/main.dex"
wait "$_bg"
_bg_rc=$(cat "$T/bg.rc" 2>/dev/null)
_bg_out=$(cat "$T/bg.out" 2>/dev/null)
PRELOCK_SLEEP=
PRELOCK_MARK=
[ "$_bg_rc" = 0 ] && ok "持锁后重查返回成功" || bad "持锁后重查退出码 $_bg_rc"
has "$_bg_out" '无需重复' && ok "持锁后发现已 patched 走 no-op" \
  || bad "持锁后没有重查状态：$_bg_out"
[ "$(backup_count)" = 0 ] && ok "持锁后重查没有产生新备份" \
  || bad "持锁后重查产生了备份：$(backup_count)"
reset_original

# ---------- 16) 并发锁 ----------
reset_hooks
clean_data
reset_original
mkdir -p "$DATA/.si-patch.lock"
run_capture apply
[ "$RC" = 0 ] && ok "空 pid 的新鲜锁等待 1 秒后可回收" \
  || bad "空 pid 的锁没有回收（$RC）：$ERR"
[ "$(target_sha)" = "$PATCH_SHA_EXPECT" ] && ok "空 pid 锁回收后 apply 成功" \
  || bad "空 pid 锁回收后 apply 没生效"
run_capture restore
[ "$RC" = 0 ] && [ "$(target_sha)" = "$ORIG_SHA" ] && ok "空 pid 锁用例收尾恢复原版" \
  || bad "空 pid 锁用例收尾恢复失败"
clean_data
reset_original
cat > "$T/holder/si-patch.sh" <<'S'
#!/bin/sh
while :; do sleep 1; done
S
chmod 755 "$T/holder/si-patch.sh"
"$TEST_SH" "$T/holder/si-patch.sh" &
HOLDER=$!
sleep 0.3
mkdir -p "$DATA/.si-patch.lock"
printf '%s\n' "$HOLDER" > "$DATA/.si-patch.lock/pid"
run_capture apply
[ "$RC" = 4 ] && ok "并发锁让 apply 退出码 4" || bad "并发锁退出码不对：$RC"
has "$ERR" '正在进行' && ok "并发锁提示明确" || bad "并发锁提示不清：$ERR"
[ "$(target_sha)" = "$ORIG_SHA" ] && ok "并发锁生效时没动目标" || bad "并发锁生效时改了目标"
kill -9 "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
HOLDER=
run_capture apply
[ "$RC" = 0 ] && ok "死 PID 的旧锁可自动回收" || bad "旧锁没有回收（$RC）：$ERR"
[ "$(target_sha)" = "$PATCH_SHA_EXPECT" ] && ok "回收旧锁后 apply 成功" || bad "回收旧锁后 apply 没生效"
[ ! -d "$DATA/.si-patch.lock" ] && ok "apply 结束释放锁" || bad "apply 结束没释放锁"
run_capture restore
[ "$RC" = 0 ] && [ "$(target_sha)" = "$ORIG_SHA" ] && ok "并发用例收尾恢复原版" \
  || bad "并发用例收尾恢复失败"

# ---------- 17) U1：patched + 有效备份 → 只保留 patch-backup，不自动恢复 ----------
M1=$T/un1/mod; D1=$T/un1/data; B1=$T/un1/bin
mkdir -p "$M1/scripts" "$D1/patch-backup" "$B1" || exit 1
cp module.prop "$M1/module.prop" || exit 1
cp "$PATCH" "$M1/scripts/si-patch.sh" || exit 1
chmod 755 "$M1/scripts/si-patch.sh"
printf 'ENABLED=1\n' > "$D1/config.conf"
printf 'unrelated\n' > "$D1/daemon.log"
: > "$D1/.hidden"
cp "$ASSET_REAL" "$B1/main.dex"
chmod 644 "$B1/main.dex"
write_prop
cp "$TARGET_DIR/module.prop" "$B1/module.prop" || exit 1
cp "$T/original.bin" "$D1/patch-backup/main.dex.20260101-000000"
chmod 600 "$D1/patch-backup/main.dex.20260101-000000"
SI_TEST=1 SI_MOD=$M1 SI_DATA=$D1 SI_PATCH_TARGET_DIR=$B1 SI_PATCH_SDK=37 \
  SI_PATCH_ORIGINAL_SHA=$ORIG_SHA SI_PATCH_ORIGINAL_SIZE=$ORIG_SIZE \
  "$TEST_SH" uninstall.sh >"$T/un1.out" 2>"$T/un1.err"
_rc=$?
[ "$_rc" = 0 ] && ok "U1 卸载脚本成功退出" || bad "U1 卸载脚本退出码 $_rc"
[ "$(sha_of "$B1/main.dex")" = "$PATCH_SHA_EXPECT" ] && ok "U1 不自动恢复 main.dex" \
  || bad "U1 仍自动恢复了 main.dex"
[ -d "$D1/patch-backup" ] && [ -f "$D1/patch-backup/main.dex.20260101-000000" ] \
  && ok "U1 保留 patch-backup" || bad "U1 patch-backup 被删"
[ ! -e "$D1/config.conf" ] && [ ! -e "$D1/daemon.log" ] && [ ! -e "$D1/.hidden" ] \
  && ok "U1 其他数据照旧删除（含隐藏文件）" || bad "U1 其他数据没有删干净"
[ "$(ls -A "$D1" 2>/dev/null)" = patch-backup ] && ok "U1 数据目录只剩 patch-backup" \
  || bad "U1 数据目录残留：$(ls -A "$D1" 2>/dev/null)"
has "$(cat "$T/un1.out" 2>/dev/null)" '补丁备份保留在' \
  && ok "U1 输出保留路径" || bad "U1 输出没有保留路径"
has "$(cat "$T/un1.out" 2>/dev/null)" '未自动恢复原版' \
  && ok "U1 输出说明未自动恢复" || bad "U1 输出没有说明未自动恢复"

# ---------- 18) U1：unknown + 有效备份 → 保留备份 ----------
M2=$T/un2/mod; D2=$T/un2/data; B2=$T/un2/bin
mkdir -p "$M2/scripts" "$D2/patch-backup" "$B2" || exit 1
cp module.prop "$M2/module.prop" || exit 1
cp "$PATCH" "$M2/scripts/si-patch.sh" || exit 1
chmod 755 "$M2/scripts/si-patch.sh"
printf 'unknown main.dex fixture\n' > "$B2/main.dex"
chmod 600 "$B2/main.dex"
write_prop
cp "$TARGET_DIR/module.prop" "$B2/module.prop" || exit 1
cp "$T/original.bin" "$D2/patch-backup/main.dex.20260101-000000"
chmod 600 "$D2/patch-backup/main.dex.20260101-000000"
printf 'x\n' > "$D2/daemon.log"
_unknown_sha=$(sha_of "$B2/main.dex")
SI_TEST=1 SI_MOD=$M2 SI_DATA=$D2 SI_PATCH_TARGET_DIR=$B2 SI_PATCH_SDK=37 \
  SI_PATCH_ORIGINAL_SHA=$ORIG_SHA SI_PATCH_ORIGINAL_SIZE=$ORIG_SIZE \
  "$TEST_SH" uninstall.sh >"$T/un2.out" 2>"$T/un2.err"
_rc=$?
[ "$_rc" = 0 ] && ok "U1 unknown 卸载成功退出" || bad "U1 unknown 卸载退出码 $_rc"
[ "$(sha_of "$B2/main.dex")" = "$_unknown_sha" ] && ok "U1 unknown 目标未被改动" \
  || bad "U1 unknown 目标被改"
[ -d "$D2/patch-backup" ] && [ ! -e "$D2/daemon.log" ] \
  && ok "U1 unknown 只保留备份" || bad "U1 unknown 数据保留不对"
[ "$(ls -A "$D2" 2>/dev/null)" = patch-backup ] && ok "U1 unknown 数据目录只剩 patch-backup" \
  || bad "U1 unknown 数据目录残留：$(ls -A "$D2" 2>/dev/null)"

# ---------- 19) U1：unsupported + 有效备份 → 保留备份 ----------
M3=$T/un3/mod; D3=$T/un3/data; B3=$T/un3/bin
mkdir -p "$M3/scripts" "$D3/patch-backup" "$B3" || exit 1
cp module.prop "$M3/module.prop" || exit 1
cp "$PATCH" "$M3/scripts/si-patch.sh" || exit 1
chmod 755 "$M3/scripts/si-patch.sh"
cp "$ASSET_REAL" "$B3/main.dex"
chmod 644 "$B3/main.dex"
write_prop
cp "$TARGET_DIR/module.prop" "$B3/module.prop" || exit 1
cp "$T/original.bin" "$D3/patch-backup/main.dex.20260101-000000"
chmod 600 "$D3/patch-backup/main.dex.20260101-000000"
printf 'x\n' > "$D3/status.json"
SI_TEST=1 SI_MOD=$M3 SI_DATA=$D3 SI_PATCH_TARGET_DIR=$B3 SI_PATCH_SDK=36 \
  SI_PATCH_ORIGINAL_SHA=$ORIG_SHA SI_PATCH_ORIGINAL_SIZE=$ORIG_SIZE \
  "$TEST_SH" uninstall.sh >"$T/un3.out" 2>"$T/un3.err"
_rc=$?
[ "$_rc" = 0 ] && ok "U1 unsupported 卸载成功退出" || bad "U1 unsupported 卸载退出码 $_rc"
[ "$(sha_of "$B3/main.dex")" = "$PATCH_SHA_EXPECT" ] && ok "U1 unsupported 目标未被改动" \
  || bad "U1 unsupported 目标被改"
[ -d "$D3/patch-backup" ] && [ ! -e "$D3/status.json" ] \
  && ok "U1 unsupported 只保留备份" || bad "U1 unsupported 数据保留不对"

# ---------- 20) U1：patched 但没有有效备份 → 数据目录全删 ----------
M4=$T/un4/mod; D4=$T/un4/data; B4=$T/un4/bin
mkdir -p "$M4/scripts" "$D4" "$B4" || exit 1
cp module.prop "$M4/module.prop" || exit 1
cp "$PATCH" "$M4/scripts/si-patch.sh" || exit 1
chmod 755 "$M4/scripts/si-patch.sh"
cp "$ASSET_REAL" "$B4/main.dex"
chmod 644 "$B4/main.dex"
write_prop
cp "$TARGET_DIR/module.prop" "$B4/module.prop" || exit 1
printf 'x\n' > "$D4/daemon.log"
SI_TEST=1 SI_MOD=$M4 SI_DATA=$D4 SI_PATCH_TARGET_DIR=$B4 SI_PATCH_SDK=37 \
  SI_PATCH_ORIGINAL_SHA=$ORIG_SHA SI_PATCH_ORIGINAL_SIZE=$ORIG_SIZE \
  "$TEST_SH" uninstall.sh >"$T/un4.out" 2>"$T/un4.err"
_rc=$?
[ "$_rc" = 0 ] && ok "U1 无有效备份时卸载成功退出" || bad "U1 无备份卸载退出码 $_rc"
[ ! -d "$D4" ] && ok "U1 无有效备份时数据目录全删" || bad "U1 无有效备份时数据目录还在"

# ---------- 21) U1：目标已是原版但备份在 → 仍保守保留 patch-backup ----------
M5=$T/un5/mod; D5=$T/un5/data; B5=$T/un5/bin
mkdir -p "$M5/scripts" "$D5/patch-backup" "$B5" || exit 1
cp module.prop "$M5/module.prop" || exit 1
cp "$PATCH" "$M5/scripts/si-patch.sh" || exit 1
chmod 755 "$M5/scripts/si-patch.sh"
cp "$T/original.bin" "$B5/main.dex"
chmod 600 "$B5/main.dex"
write_prop
cp "$TARGET_DIR/module.prop" "$B5/module.prop" || exit 1
cp "$T/original.bin" "$D5/patch-backup/main.dex.20260101-000000"
chmod 600 "$D5/patch-backup/main.dex.20260101-000000"
printf 'x\n' > "$D5/daemon.log"
SI_TEST=1 SI_MOD=$M5 SI_DATA=$D5 SI_PATCH_TARGET_DIR=$B5 SI_PATCH_SDK=37 \
  SI_PATCH_ORIGINAL_SHA=$ORIG_SHA SI_PATCH_ORIGINAL_SIZE=$ORIG_SIZE \
  "$TEST_SH" uninstall.sh >"$T/un5.out" 2>"$T/un5.err"
_rc=$?
[ "$_rc" = 0 ] && ok "U1 原版卸载成功退出" || bad "U1 原版卸载退出码 $_rc"
[ -d "$D5/patch-backup" ] && [ ! -e "$D5/daemon.log" ] \
  && ok "U1 目标原版但有备份时只保留 patch-backup" \
  || bad "U1 原版仍把备份一起删了"

# ---------- 22) U1：脚本缺失但备份在 → 保守保留 patch-backup ----------
M6=$T/un6/mod; D6=$T/un6/data
mkdir -p "$M6" "$D6/patch-backup" || exit 1
cp module.prop "$M6/module.prop" || exit 1
cp "$T/original.bin" "$D6/patch-backup/main.dex.20260101-000000"
chmod 600 "$D6/patch-backup/main.dex.20260101-000000"
printf 'x\n' > "$D6/daemon.log"
SI_TEST=1 SI_MOD=$M6 SI_DATA=$D6 "$TEST_SH" uninstall.sh >"$T/un6.out" 2>"$T/un6.err"
_rc=$?
[ "$_rc" = 0 ] && ok "U1 脚本缺失时卸载成功退出" || bad "U1 脚本缺失卸载退出码 $_rc"
[ -d "$D6/patch-backup" ] && [ ! -e "$D6/daemon.log" ] \
  && ok "U1 脚本缺失时保守保留 patch-backup" || bad "U1 脚本缺失时备份未保留"

# ---------- 23) U1：sha256sum 失效（BACKUP_OK=0）仍保留 patch-backup ----------
cat > "$T/fakebin/sha256sum" <<'S'
#!/bin/sh
exit 1
S
chmod 755 "$T/fakebin/sha256sum"
M7=$T/un7/mod; D7=$T/un7/data; B7=$T/un7/bin
mkdir -p "$M7/scripts" "$D7/patch-backup" "$B7" || exit 1
cp module.prop "$M7/module.prop" || exit 1
cp "$PATCH" "$M7/scripts/si-patch.sh" || exit 1
chmod 755 "$M7/scripts/si-patch.sh"
cp "$ASSET_REAL" "$B7/main.dex"
chmod 644 "$B7/main.dex"
write_prop
cp "$TARGET_DIR/module.prop" "$B7/module.prop" || exit 1
cp "$T/original.bin" "$D7/patch-backup/main.dex.20260101-000000"
chmod 600 "$D7/patch-backup/main.dex.20260101-000000"
printf 'x\n' > "$D7/daemon.log"
_chk7=$(PATH="$T/fakebin:$PATH" SI_TEST=1 SI_DATA=$D7 SI_PATCH_TARGET_DIR=$B7 \
  SI_PATCH_SDK=37 SI_PATCH_ORIGINAL_SHA=$ORIG_SHA SI_PATCH_ORIGINAL_SIZE=$ORIG_SIZE \
  "$TEST_SH" "$PATCH" check)
printf '%s\n' "$_chk7" | grep -q '^BACKUP_OK=0$' \
  && ok "sha256sum 失效夹具：BACKUP_OK=0" || bad "sha256sum 夹具没有让 BACKUP_OK=0"
# uninstall.sh 自身也要能找到 sed/rm 等常用命令，只把 fakebin 放在 PATH 最前面。
PATH="$T/fakebin:$PATH" SI_TEST=1 SI_MOD=$M7 SI_DATA=$D7 SI_PATCH_TARGET_DIR=$B7 \
  SI_PATCH_SDK=37 SI_PATCH_ORIGINAL_SHA=$ORIG_SHA SI_PATCH_ORIGINAL_SIZE=$ORIG_SIZE \
  "$TEST_SH" uninstall.sh >"$T/un7.out" 2>"$T/un7.err"
_rc=$?
[ "$_rc" = 0 ] && ok "U1 sha256sum 失效时卸载成功退出" || bad "U1 sha256sum 失效卸载退出码 $_rc"
[ -d "$D7/patch-backup" ] && [ -f "$D7/patch-backup/main.dex.20260101-000000" ] \
  && ok "U1 sha256sum 失效时仍保留备份" || bad "U1 sha256sum 失效时备份被删"
[ ! -e "$D7/daemon.log" ] && ok "U1 sha256sum 失效时其他数据仍删除" \
  || bad "U1 sha256sum 失效时其他数据残留"
has "$(cat "$T/un7.out" 2>/dev/null)" '补丁备份保留在' \
  && ok "U1 sha256sum 失效时仍打印备份路径" || bad "U1 sha256sum 失效时没有路径提示"
rm -f "$T/fakebin/sha256sum"

# ---------- 24) WebUI / action / build / 文档（静态） ----------
grep -q 'P.patch = P.mod' webroot/index.html && ok "WebUI 指向 si-patch.sh" \
  || bad "WebUI 没接线 si-patch.sh"
grep -q 'patchPromptPath' webroot/index.html && grep -q '\.patch_prompted\.' webroot/index.html \
  && ok "WebUI 使用按目标/版本区分的提示标记" || bad "WebUI 提示标记没有按目标/版本区分"
grep -q 'PROMPT_TAG' scripts/si-patch.sh && grep -q '\.patch_prompted\.\$PROMPT_TAG' scripts/si-patch.sh \
  && ok "si-patch.sh 提示标记按目标/版本区分" || bad "si-patch.sh 提示标记没有按目标/版本区分"
grep -q 'Android 17 应用列表修复（main.dex）' webroot/index.html \
  && ok "补丁卡片标题含 main.dex" || bad "补丁卡片标题没含 main.dex"
for _id in patchCard patchHint patchActions patchCheckRow patchTiming btnPatchCheck \
           btnPatchApply btnPatchRestore btnPatchForce \
           patchConfirm btnPatchConfirmGo btnPatchConfirmCancel patchResult; do
  grep -q "id=\"$_id\"" webroot/index.html || bad "WebUI 缺少元素 $_id"
done
grep -q 'patch-confirm-go' webroot/index.html && grep -q 'patch-confirm-cancel' webroot/index.html \
  && ok "WebUI 确认按钮已接线" || bad "WebUI 确认按钮没接线"
grep -q "btnPatchConfirmGo').addEventListener('click', confirmPatchAction)" webroot/index.html \
  && ok "确认按钮调用 confirmPatchAction" || bad "确认按钮没调用 confirmPatchAction"
grep -q "btnPatchApply').addEventListener('click', function () { armPatchAction('apply'); })" \
  webroot/index.html && ok "应用按钮先 arm 再确认" || bad "应用按钮没有两步确认"
grep -q "btnPatchRestore').addEventListener('click', function () { armPatchAction('restore'); })" \
  webroot/index.html && ok "恢复按钮先 arm 再确认" || bad "恢复按钮没有两步确认"
grep -q "btnPatchForce').addEventListener('click', function () { armPatchAction('force'); })" \
  webroot/index.html && ok "强制恢复先 arm 再确认" || bad "强制恢复没有两步确认"
grep -q "btnPatchCheck').addEventListener('click', function () { loadPatch(true); })" \
  webroot/index.html && ok "检查补丁按钮强制重查" || bad "检查补丁按钮没接线"
grep -q "act === 'patch-apply') { armPatchAction('apply'); }" webroot/index.html \
  && ok "banner 应用按钮也走两步确认" || bad "banner 应用按钮直接执行"
grep -q "act === 'patch-confirm-go') { confirmPatchAction(); }" webroot/index.html \
  && ok "banner 确认按钮执行" || bad "banner 确认按钮没接线"
grep -q 'p.targetVersion' webroot/index.html && grep -q 'p.targetFile' webroot/index.html \
  && grep -q '仅适用于' webroot/index.html && ok "确认框显示模块版本与适用范围" \
  || bad "确认框缺少模块版本/适用范围"
grep -q 'state.patchConfirm' webroot/index.html && ok "WebUI 有确认状态" \
  || bad "WebUI 没有确认状态"
grep -q 'patchError' webroot/index.html && ok "WebUI 有补丁错误状态" \
  || bad "WebUI 没有补丁错误状态"
_run_refs=$(grep -c 'runPatchAction' webroot/index.html)
[ "$_run_refs" = 2 ] && ok "runPatchAction 只在确认后调用（2 处）" \
  || bad "runPatchAction 调用点不对：$_run_refs"
[ "$(grep -c "P.patch + ' check'" webroot/index.html)" = 1 ] \
  && ok "补丁 check 只保留一个后台入口" || bad "补丁 check 入口数量不对"
grep -q "runBg('sh ' + P.patch + ' check'" webroot/index.html \
  && ok "补丁 check 走后台执行" || bad "补丁 check 没有走后台执行"
grep -q 'verifyPatchAction' webroot/index.html && bad "仍存在全量动作后复核函数" \
  || ok "已删除全量动作后复核函数"
grep -q 'verifyPatchTarget' webroot/index.html && grep -q 'stat -c "%s %Y"' webroot/index.html \
  && ok "动作后只用 stat+sha256 复核一次" || bad "动作后没有单次 stat 复核"
grep -q 'applyPatchState' webroot/index.html && ok "动作后直接更新卡片状态" \
  || bad "动作后没有直接更新卡片状态"
grep -q 'errnoKnown: false' webroot/index.html \
  && grep -q 'res.errnoKnown !== false' webroot/index.html \
  && ok "sync 桥接不伪造 errno=0" || bad "sync 桥接仍把 errno 固定为 0"
grep -q 'patchActionVerdict(action, text, errnoKnown, errno, unknown)' webroot/index.html \
  && grep -q "var marker = isApply ? '已应用补丁' : '已恢复原版'" webroot/index.html \
  && ok "动作判定支持 unknown/输出标记" || bad "动作判定缺少 unknown 分支"
grep -q '结果未知，请刷新检查' webroot/index.html \
  && ok "超时/无 errno 显示结果未知" || bad "缺少结果未知文案"
grep -q '已应用，重启手机生效' webroot/index.html && ok "WebUI 应用成功文案" \
  || bad "WebUI 缺少应用成功文案"
grep -q '已恢复原版，重启手机生效' webroot/index.html && ok "WebUI 恢复成功文案" \
  || bad "WebUI 缺少恢复成功文案"
grep -q "p.lastAction === 'restored'" webroot/index.html \
  && grep -q '已恢复原版，重启生效（Zygisk 模块在开机时加载）。' webroot/index.html \
  && ok "restore 成功后卡片显示已恢复原版/重启生效" \
  || bad "restore 成功卡片没有重启提示"
grep -q "p.lastAction === 'applied'" webroot/index.html \
  && ok "apply 成功后卡片显示已应用" || bad "apply 成功卡片没有提示"
grep -q '重启生效（Zygisk 模块在开机时加载）' webroot/index.html \
  && ok "WebUI 提示重启生效" || bad "WebUI 没提示重启生效"
grep -q "if (sdk !== '37') { hidePatchCard(); return false; }" webroot/index.html \
  && ok "SDK!=37 在 check 前隐藏卡片（SDK 14/15）" \
  || bad "WebUI 没有在 check 前按 SDK 隐藏"
grep -q "state.patchSdk !== '37'" webroot/index.html \
  && ok "render/arm 也按 SDK 门禁" || bad "WebUI 缺少 patchSdk 门禁"
grep -q "applyBtn.disabled = !canAct || !p || !p.match || actionBusy('patchApply')" webroot/index.html \
  && ok "版本/哈希不匹配时 apply 置灰且独立 busy" || bad "apply 置灰/独立 busy 不对"
grep -q "restoreBtn.disabled = !canAct || !p || !p.match || !p.backupOk || actionBusy('patchRestore')" webroot/index.html \
  && ok "restore 置灰条件与独立 busy" || bad "restore 置灰条件不对"
grep -q "forceBtn.disabled = !canAct || !p || !p.match || actionBusy('patchForce')" webroot/index.html \
  && ok "强制恢复置灰条件与独立 busy" || bad "强制恢复置灰条件不对"
grep -q "forceOk = !!(p && p.match && p.backupOk && st === 'unknown')" webroot/index.html \
  && ok "U2：版本不匹配时隐藏强制恢复" || bad "U2 强制恢复仍不检查版本"
grep -q "(action === 'force' && p.match && p.backupOk && p.state === 'unknown')" webroot/index.html \
  && ok "U2：arm 强制恢复也检查版本" || bad "U2 arm 强制恢复缺版本门禁"
grep -q "applyBtn.hidden = !(st === 'original' || st === 'patched-legacy')" webroot/index.html \
  && grep -q "restoreBtn.hidden = !(st === 'patched' || st === 'patched-legacy')" webroot/index.html \
  && grep -q "forceBtn.hidden = !forceOk" webroot/index.html \
  && ok "original/legacy 可升级 / patched+legacy 可恢复 / unknown 强制恢复" \
  || bad "补丁按钮显示条件不对"
grep -q "state.patchSdk === '37' && p.sdk === '37'" webroot/index.html \
  && ok "首次提示只给 SDK37+匹配" || bad "首次提示缺 SDK/匹配门禁"
grep -q 'SI_MATCH' webroot/index.html && grep -q 'BACKUP_OK' webroot/index.html \
  && ok "WebUI 读取版本门禁与有效备份字段" || bad "WebUI 没读新字段"
grep -q 'p.originalSha' webroot/index.html && grep -q 'p.originalSize' webroot/index.html \
  && ok "WebUI 用原版哈希/大小更新恢复后的卡片" || bad "WebUI 没记录原版哈希/大小"
grep -q 'MTIME' scripts/si-patch.sh && grep -q 'p.mtime' webroot/index.html \
  && ok "check 输出 mtime 且 WebUI 读入缓存键" || bad "mtime 缓存键缺失"
grep -q 'PATCH_CACHE_TTL = 30000' webroot/index.html \
  && grep -q 'patchCacheUsable' webroot/index.html \
  && grep -q 'statPatchTarget' webroot/index.html \
  && grep -q 'st.sha === state.patchCache.sha' webroot/index.html \
  && ok "补丁状态 30 秒缓存 + mtime/size/sha 校验" || bad "补丁缓存缺失"
grep -q 'BG_POLL_MS = 300' webroot/index.html && grep -q 'function runBg' webroot/index.html \
  && ok "长动作后台执行 + 300ms 轮询" || bad "后台轮询缺失"
grep -q "runBg(cmd, {" webroot/index.html && grep -q 'timeoutMs: FIX_TIMEOUT' webroot/index.html \
  && ok "fix 走后台执行并带 30s 超时" || bad "fix 没走后台/超时"
grep -q "runBg('sh ' + P.restart" webroot/index.html \
  && ok "restart 走后台执行" || bad "restart 没走后台"
grep -q "runBg('sh ' + P.patch + ' ' + cmd" webroot/index.html \
  && ok "apply/restore 走后台执行" || bad "apply/restore 没走后台"
grep -q 'runBg(cmd, { timeoutMs: 5000 })' webroot/index.html \
  && ok "保存配置写文件走后台执行" || bad "保存配置没走后台"
grep -q 'state.patchMarked && state.patchMarkedKey === path' webroot/index.html \
  && ok "patchMarked 存在时不再重复写提示标记" || bad "提示标记仍会重复写"
if grep -q 'if (patchPromptable()) { markPatchPrompted(); }' webroot/index.html; then
  bad "renderStateBanner 仍在渲染时写提示标记"
else
  ok "提示标记只在暂不/动作成功时写"
fi
grep -q 'actionOk && state.patch' webroot/index.html \
  && grep -q 'state.patchCache = null;' webroot/index.html \
  && ok "动作失败/超时不写缓存、不置 prompted" || bad "失败动作仍写缓存"
grep -q 'CHECK_TIMEOUT = 8000' webroot/index.html \
  && grep -q 'FIX_TIMEOUT = 30000' webroot/index.html \
  && grep -q 'RESTART_TIMEOUT = 10000' webroot/index.html \
  && ok "check/fix/restart 超时 8/30/10s" || bad "长命令超时不对"
grep -q 'setPatchTiming' webroot/index.html && grep -q "检查 ' + state.patchCheckMs + 'ms'" webroot/index.html \
  && ok "页面显示检查耗时/超时反馈" || bad "缺少检查耗时反馈"
grep -q 'state.patchSdk === .37. && !actionBusy(.patchCheck.)' webroot/index.html \
  && grep -q '正在检查补丁状态，请稍候' webroot/index.html \
  && ok "check 进行中置灰动作按钮并提示检查中" || bad "check 进行中没有置灰动作按钮"
grep -q 'clearPatchResult' webroot/index.html && grep -q 'clearPatchResult();' webroot/index.html \
  && ok "loadPatch 清掉旧 patchResult" || bad "loadPatch 没有清旧结果"
grep -q 'loadPatch(false)' webroot/index.html && grep -q 'loadPatch(true)' webroot/index.html \
  && ok "刷新用缓存 / 手动检查强制重查" || bad "刷新链仍强制 check"
grep -q 'function syncTopButtons' webroot/index.html \
  && grep -q 'state.actionBusy' webroot/index.html \
  && grep -q "beginAction(key)" webroot/index.html \
  && ok "按钮独立 busy" || bad "仍不是独立 busy"
if grep -q 'state.patchBusy\|function setBusy\|setBusy(' webroot/index.html; then
  bad "仍有全局 patchBusy/setBusy"
else
  ok "已移除全局 patchBusy/setBusy"
fi
grep -Fq "var styles = ['cb3', 'cb2', 'sync']" webroot/index.html \
  && ok "桥接探测仍 cb3 → cb2 → sync" || bad "桥接探测顺序被改"
grep -q '已应用，可恢复原版' webroot/index.html && ok "WebUI 已应用文案" \
  || bad "WebUI 缺少已应用文案"
grep -q "st === 'patched-legacy'" webroot/index.html \
  && grep -q 'badge = .旧版补丁.' webroot/index.html \
  && grep -q '检测到社区版补丁' webroot/index.html \
  && ok "WebUI 旧版补丁 badge/升级提示" || bad "WebUI legacy 提示缺失"
grep -q "applyBtn.textContent = st === 'patched-legacy' ? '升级到自建版' : '应用补丁'" webroot/index.html \
  && grep -q "确认升级到自建版" webroot/index.html \
  && ok "WebUI legacy 升级按钮/确认文案" || bad "WebUI legacy 升级按钮缺失"
grep -q 'p.legacy = toInt(p.LEGACY, 0) === 1' webroot/index.html \
  && grep -q 'applyPatchState(action, fromLegacy)' webroot/index.html \
  && ok "WebUI 读取 LEGACY 并区分升级来源" || bad "WebUI legacy 状态接线缺失"
grep -q 'badge = .未知版本.' webroot/index.html \
  && grep -q 'badge = .版本不匹配.' webroot/index.html \
  && ok "未知版本/版本不匹配 badge 文案" || bad "badge 文案不对"
grep -q 'btn primary act-btn' webroot/index.html \
  && grep -q 'btn ghost act-btn' webroot/index.html \
  && grep -q 'btn danger act-btn' webroot/index.html \
  && grep -q 'id="btnPatchCheck" disabled' webroot/index.html \
  && grep -q 'patch-actions' webroot/index.html \
  && grep -q 'patch-check-row' webroot/index.html \
  && ok "动作按钮统一 act-btn/patch-actions" || bad "动作按钮 class 不统一"
if grep -q 'btn tiny ghost" id="btnPatchCheck"' webroot/index.html; then
  bad "检查补丁仍是 tiny/无统一 class"
else
  ok "检查补丁不再 tiny"
fi
if grep -q 'style="flex:1"' webroot/index.html || grep -q 'style="margin-top:10px"' webroot/index.html; then
  bad "动作按钮仍有内联大小样式"
else
  ok "动作按钮无内联大小样式"
fi
grep -q '.btn.act-btn{height:44px;min-width:120px;padding:0 16px;font-size:13.5px;border-radius:11px;margin:0}' webroot/index.html \
  && grep -q '.patch-actions{display:grid' webroot/index.html \
  && grep -q '.patch-check-row .btn{flex:0 0 auto;width:auto}' webroot/index.html \
  && grep -q '#patchBadge{flex:none;margin-left:auto;text-align:right;white-space:nowrap' webroot/index.html \
  && grep -q '#patchCard .card-head{.*flex-wrap:wrap' webroot/index.html \
  && ok "按钮同尺寸/网格对齐/badge 右对齐 CSS" || bad "按钮/badge CSS 未归一化"
grep -q '是未知版本' webroot/index.html && ok "WebUI unknown 提示改为未知版本" \
  || bad "WebUI 缺少未知版本提示"
grep -q '版本不匹配时不允许强制恢复' webroot/index.html \
  && ok "WebUI unknown 版本不匹配时提示不能强制恢复" \
  || bad "WebUI unknown 版本不匹配提示不对"
grep -q "st !== 'patched-legacy'" webroot/index.html \
  && grep -q "st !== 'unknown'" webroot/index.html \
  && ok "no-target/unsupported 隐藏卡片且 legacy 可见" || bad "no-target/legacy 可见性不对"
if grep -q 'SERVER_PIDS\|serverPids\|server-v355\|restart_si_server\|TERM_WAIT\|RESTART_WAIT' webroot/index.html; then
  bad "WebUI 仍含 SERVER_PIDS/server 重启残留"
else
  ok "WebUI 已移除 SERVER_PIDS/server 重启/等待"
fi
if grep -q '/proc/' webroot/index.html; then
  bad "WebUI 仍引用 /proc"
else
  ok "WebUI 不引用 /proc"
fi
if grep -q '18 秒' webroot/index.html; then
  bad "WebUI 仍有 18 秒等待文案"
else
  ok "WebUI 没有 18 秒等待文案"
fi
grep -q 'si-patch\.sh" status' action.sh && ok "action.sh 显示补丁状态" \
  || bad "action.sh 没有补丁状态"
grep -q 'si-patch\.sh" apply' action.sh && bad "action.sh 会自动 apply" \
  || ok "action.sh 不自动 apply"
grep -q 'patch_txt=${patch_txt#main.dex 补丁：}' action.sh \
  && ok "action.sh 去掉 main.dex 补丁前缀" || bad "action.sh 前缀剥离不对"
grep -q 'PATCH_DEX=/data/adb/modules/zygisk-storage-isolation/main.dex' uninstall.sh \
  && ok "uninstall.sh 默认目标 main.dex" || bad "uninstall.sh 目标不对"
grep -q 'PATCH_KEEP_BACKUP=1' uninstall.sh && grep -q '补丁备份保留在' uninstall.sh \
  && ok "U1：卸载保留 patch-backup 并打印路径" || bad "U1 卸载没有保留备份"
grep -Fq '"$DATA/patch-backup/main.dex".*' uninstall.sh \
  && ok "U1：按 main.dex.* 文件存在保守保留" || bad "U1 没有按备份文件存在保留"
if grep -q 'BACKUP_OK' uninstall.sh; then
  bad "U1 仍依赖 BACKUP_OK"
else
  ok "U1 不依赖 BACKUP_OK/sha256sum"
fi
grep -q '未自动恢复原版' uninstall.sh && ok "U1：卸载不自动恢复" \
  || bad "U1 卸载文案不对"
if grep -q 'PATCH_SCRIPT" restore' uninstall.sh; then
  bad "U1 卸载仍调用 restore"
else
  ok "U1 卸载不再调用 restore"
fi
grep -q '版本不匹配时不能用原版备份覆盖' scripts/si-patch.sh \
  && ok "U2：CLI restore 版本门禁" || bad "U2 CLI 没有版本门禁"
grep -q 'assets/main.dex' tools/build.sh && ok "构建脚本包含 main.dex 资产" \
  || bad "构建脚本没有 main.dex 资产"
grep -q 'PATCH_SHA=5413a01b6c49f360f3851af60be8820fcb8a4595d0c15697fcebac88b6d73891' tools/build.sh && ok "构建脚本校验完整补丁 sha" \
  || bad "构建脚本没有校验补丁 sha"
grep -q '88336' tools/build.sh && ok "构建脚本校验补丁大小" \
  || bad "构建脚本没有校验补丁大小"
grep -q 'siPatchModule' tools/build.sh && grep -q 'siPatchTarget' tools/build.sh \
  && ok "构建脚本校验适用模块/目标字段" || bad "构建脚本没有校验适用字段"
[ -f CHANGELOG.md ] && grep -q '^## 1.5.6' CHANGELOG.md \
  && ! grep -q '^## 1.5.5' CHANGELOG.md \
  && ! grep -q '^## 1.5.4' CHANGELOG.md \
  && ! grep -q '^## 1.5.3' CHANGELOG.md \
  && ! grep -q '^## 1.5.2' CHANGELOG.md \
  && ! grep -q '^## 1.5.1' CHANGELOG.md \
  && ! grep -q '^## 1.5.0' CHANGELOG.md \
  && [ "$(grep -c '^## ' CHANGELOG.md)" = 1 ] \
  && ok "CHANGELOG 只列出 1.5.6" || bad "CHANGELOG 不是只含 1.5.6"
grep -q 'raw/main/CHANGELOG.md' update.json && ok "update.json 指向 CHANGELOG" \
  || bad "update.json 没指向 CHANGELOG"
grep -q 'CHANGELOG.md' tools/build.sh && ok "构建脚本打包 CHANGELOG" \
  || bad "构建脚本没有打包 CHANGELOG"
grep -q '88,336' README.md && grep -q '5413a01b6c49f360f3851af60be8820fcb8a4595d0c15697fcebac88b6d73891' README.md \
  && ok "README 写自建 main.dex 大小/完整哈希" || bad "README 哈希/大小不对"
grep -q '5413a01b6c49f360f3851af60be8820fcb8a4595d0c15697fcebac88b6d73891' CHANGELOG.md \
  && ok "CHANGELOG 写完整 main.dex 哈希" || bad "CHANGELOG 哈希不对"
grep -q '6d4058bc1c66fc14dec2331a603404a59c271d8a4b8f63c5270ff7029a8b80a7' CHANGELOG.md README.md \
  && ok "README/CHANGELOG 写完整社区旧版哈希" || bad "README/CHANGELOG 缺少社区旧版哈希"
grep -q 'patched-legacy' README.md && grep -q 'main.dex.legacy' README.md \
  && grep -q 'LEGACY' README.md \
  && ok "README 说明 patched-legacy/legacy 备份/LEGACY" \
  || bad "README 缺少 legacy 说明"
grep -q '二十一个' README.md && ok "README 说明 check 21 个字段" \
  || bad "README 字段数说明不对"
_bad_hash=60be88''02
if grep -q "$_bad_hash" README.md CHANGELOG.md scripts/si-patch.sh tools/build.sh; then
  bad "仍有 main.dex 哈希笔误"
else
  ok "没有 main.dex 哈希笔误"
fi
grep -q '446 方法' README.md && grep -q '剥离调试信息' README.md \
  && ok "README 说明反编译改动与剥离调试信息" || bad "README 缺少反编译说明"
grep -q 'main.dex' README.md && grep -q 'zygisk-storage-isolation' README.md \
  && ok "README 说明 main.dex / zygisk 模块" || bad "README 缺少 main.dex 说明"
! grep -q 'server-v355' README.md && ok "README 已移除 server-v355 描述" \
  || bad "README 仍有 server-v355"
grep -q 'patch-backup/main.dex' README.md && ok "README 说明 main.dex 备份路径" \
  || bad "README 缺少备份路径"
grep -q '重启手机' README.md && ok "README 说明重启生效" || bad "README 缺少重启说明"
grep -q '官方更新' README.md && grep -q '覆盖' README.md \
  && ok "README 说明官方更新覆盖后需重打" || bad "README 缺少更新覆盖说明"
grep -q '卸载不会自动恢复' README.md && ok "README 说明 U1 卸载不自动恢复" \
  || bad "README 缺少 U1 说明"
grep -q '版本不匹配时' README.md && ok "README 说明 U2 版本门禁" \
  || bad "README 缺少 U2 说明"
grep -q '^## ' HISTORY.md && ok "HISTORY 保留演化记录" || bad "HISTORY 缺失"
if grep -q '^[[:space:]]*\.result\.info' webroot/index.html; then
  ok "info 结果有独立样式"
else
  bad "缺少 .result.info 样式"
fi

# ---------- 25) WebUI 动作判定（node 实跑生产函数） ----------
if command -v node >/dev/null 2>&1; then
  sed -n '/PATCH-VERDICT-START/,/PATCH-VERDICT-END/p' webroot/index.html \
    | sed '/PATCH-VERDICT-START/d;/PATCH-VERDICT-END/d' > "$T/verdict.js"
  cat >> "$T/verdict.js" <<'JS'
function t(name, got, tone, titlePart, bodyPart) {
  var ok = got && got.tone === tone && (!titlePart || got.title.indexOf(titlePart) >= 0) &&
    (!bodyPart || String(got.body || '').indexOf(bodyPart) >= 0);
  console.log((ok ? '  ok   ' : '  FAIL ') + name + (ok ? '' : ' -> ' + JSON.stringify(got)));
  if (!ok) process.exitCode = 1;
}
t('apply 成功→good/重启提示', patchActionVerdict('apply',
  '已应用补丁：/x/main.dex\n重启生效（Zygisk 模块在开机时加载）。', true, 0, false),
  'good', '已应用，重启手机生效', '重启生效（Zygisk 模块在开机时加载）');
t('restore 成功（sync 无退出码）→good', patchActionVerdict('restore',
  '已恢复原版：/x/main.dex', false, null, false), 'good', '已恢复原版，重启手机生效');
t('force 成功→good', patchActionVerdict('force',
  '已恢复原版：/x/main.dex', true, 0, false), 'good', '已恢复原版，重启手机生效');
t('已 patched 再 apply→info', patchActionVerdict('apply',
  'main.dex 补丁已应用，无需重复操作（恢复原版请用 restore）。', true, 0, false),
  'info', '无需重复操作');
t('apply 退出码非 0→bad', patchActionVerdict('apply', 'si-patch: 写入失败', true, 5, false),
  'bad', '补丁应用失败');
t('restore 退出码非 0→bad', patchActionVerdict('restore', 'si-patch: 没有备份', true, 5, false),
  'bad', '恢复失败');
t('sync 无成功标记→结果未知', patchActionVerdict('apply', '', false, null, false),
  'warn', '结果未知，请刷新检查', '请点「检查补丁」');
t('超时→结果未知', patchActionVerdict('apply', '', true, null, true),
  'warn', '结果未知，请刷新检查');
t('known 0 无输出→good（交给 stat 复核）', patchActionVerdict('apply', '', true, 0, false),
  'good', '已应用，重启手机生效');
t('legacy 升级文本（sync 无退出码）→good', patchActionVerdict('apply',
  '已从社区版升级到自建补丁：/x/main.dex', false, null, false),
  'good', '已应用，重启手机生效');
JS
  if node "$T/verdict.js"; then
    ok "WebUI 动作判定 10 个场景通过（node 实跑生产函数）"
  else
    bad "WebUI 动作判定用例失败"
  fi
else
  echo "  note 未安装 node，跳过 WebUI 动作判定用例"
fi

echo
[ "$fail" = 0 ] && { echo "patch.test: PASS"; exit 0; }
echo "patch.test: FAIL"; exit 1
