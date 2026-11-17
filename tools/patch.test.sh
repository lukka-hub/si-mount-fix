#!/system/bin/sh
# si-patch.sh / WebUI / uninstall 补丁接线回归：
#   SDK≠37、无 SI、原版→apply（备份存在）、已 patched no-op、unknown 拒绝、
#   asset 缺失/哈希不对、备份创建哈希、复制失败回滚、mv 后校验与真实回滚、
#   chown、umask 022 下 600、restore 从新到旧选有效备份、坏备份/全坏、unknown 强制恢复、
#   restore 当前副本回滚、无备份/非 patched、持锁后重查、并发锁、卸载前恢复/失败保留。
#   fake SI 目录 + SI_TEST 钩子；补丁资产用仓库里的真实 dex。
#
# 用法：sh tools/patch.test.sh
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1
PATCH=scripts/si-patch.sh
ASSET_REAL=$PWD/assets/server-v355.dex
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

T=${TMPDIR:-/tmp}/si-patch-test.$$
DATA=$T/data
BIN=$T/si/bin
HOLDER=
cleanup() {
  [ -n "$HOLDER" ] && kill -9 "$HOLDER" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT INT TERM HUP
mkdir -p "$DATA" "$BIN" "$T/fakebin" "$T/holder" || exit 1

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

ASSET_SHA=$(sha_of "$ASSET_REAL")
PATCH_SHA_EXPECT=48ff195edf6225011404b4e914ecb7f742d1b0ff01f8e6fb60469fdec6b3c679
ORIGINAL_SHA_EXPECT=c410e8924da1a08f8fe05d8e5d36cae5eb1cb6a192bca219f9b940471db08d7a
SI_VER_OK=8.8.1.r3684.test

[ -f "$ASSET_REAL" ] && ok "补丁资产存在" || bad "补丁资产不存在：$ASSET_REAL"
[ "$ASSET_SHA" = "$PATCH_SHA_EXPECT" ] && ok "补丁资产 sha256 正确" \
  || bad "补丁资产 sha256 不对：$ASSET_SHA"
[ "$(wc -c < "$ASSET_REAL" | tr -d ' ')" = 380692 ] && ok "补丁资产大小 380692 B" \
  || bad "补丁资产大小不对：$(wc -c < "$ASSET_REAL")"
grep -q "ORIGINAL_SHA=$ORIGINAL_SHA_EXPECT" "$PATCH" \
  && ok "脚本原版 sha256 常量正确" || bad "脚本原版 sha256 常量不对"
extra_asset=0
for _f in assets/*; do
  [ "$_f" = "assets/server-v355.dex" ] || extra_asset=1
done
[ "$extra_asset" = 0 ] && ok "assets 只有 server-v355.dex（没有 main.dex）" \
  || bad "assets 里混入了其它文件"
grep -q '^siPatchVersion=8.8.1.r3684$' module.prop && ok "module.prop 提供补丁适用版本" \
  || bad "module.prop 缺少 siPatchVersion"
grep -q '^siPatchServer=server-v355$' module.prop && ok "module.prop 提供补丁适用 server" \
  || bad "module.prop 缺少 siPatchServer"

printf 'fake original server-v355.dex fixture\n' > "$T/original.bin"
ORIG_SHA=$(sha_of "$T/original.bin")
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

run_patch() {
  SI_TEST=1 SI_PATCH_DATA=$DATA SI_PATCH_BIN=$BIN SI_PATCH_ASSET=$ASSET_OVERRIDE \
    SI_PATCH_SDK=$SDK SI_PATCH_VERSION=$SI_VER_OK \
    SI_PATCH_ORIGINAL_SHA=$ORIG_SHA SI_PATCH_CP=$CP_OVERRIDE \
    SI_PATCH_CHOWN=$CHOWN_OVERRIDE SI_PATCH_PRELOCK_SLEEP=$PRELOCK_SLEEP \
    SI_PATCH_PRELOCK_MARK=$PRELOCK_MARK SI_PATCH_CORRUPT_AFTER_MV=$CORRUPT_MARK \
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
target_sha() { sha_of "$BIN/server-v355.dex"; }
reset_original() {
  cp "$T/original.bin" "$BIN/server-v355.dex" || exit 1
  chmod 600 "$BIN/server-v355.dex"
}
reset_unknown() {
  printf 'unknown server-v355.dex fixture\n' > "$BIN/server-v355.dex" || exit 1
  chmod 600 "$BIN/server-v355.dex"
}
backups() {
  [ -d "$DATA/patch-backup" ] || return 0
  for _b in "$DATA/patch-backup/server-v355.dex".*; do
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
  rm -f "$BIN"/.server-v355.dex.* 2>/dev/null
}
reset_hooks() {
  CP_OVERRIDE=
  ASSET_OVERRIDE=$ASSET_REAL
  CHOWN_OVERRIDE=
  PRELOCK_SLEEP=
  PRELOCK_MARK=
  CORRUPT_MARK=
  SDK=37
  SI_VER_OK=8.8.1.r3684.test
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

# ---------- 2) 无 SI / 无 server ----------
reset_hooks
clean_data
rm -f "$BIN/server-v355.dex"
run_capture check
[ "$RC" = 0 ] && ok "check 在 no-si 返回 0" || bad "check 在 no-si 退出码 $RC"
[ "$(kv STATE)" = no-si ] && ok "缺 server 判为 no-si" || bad "缺 server 状态不对：$(kv STATE)"
[ "$(kv SIZE)" = 0 ] && ok "no-si 的 SIZE=0" || bad "no-si 的 SIZE 不对：$(kv SIZE)"
[ -z "$(kv SHA)" ] && ok "no-si 的 SHA 为空" || bad "no-si 仍输出 SHA：$(kv SHA)"
run_capture status
has "$OUT" '未检测到' && ok "status 说明未检测到" || bad "status 没说明未检测到：$OUT"
run_capture apply
[ "$RC" != 0 ] && ok "no-si apply 拒绝" || bad "no-si apply 没有拒绝"
has "$ERR" '找不到' && ok "no-si 拒绝原因明确" || bad "no-si 拒绝原因不清：$ERR"

# ---------- 3) 原版 + 版本门禁 ----------
reset_hooks
clean_data
reset_original
run_capture check
[ "$RC" = 0 ] && ok "check 在 original 返回 0" || bad "check 在 original 退出码 $RC"
[ "$(kv STATE)" = original ] && ok "原版哈希判为 original" \
  || bad "原版哈希状态不对：$(kv STATE)"
[ "$(kv SI_MATCH)" = 1 ] && ok "SI 版本匹配时 SI_MATCH=1" \
  || bad "SI_MATCH 不对：$(kv SI_MATCH)"
[ "$(kv SI_TARGET_VERSION)" = 8.8.1.r3684 ] && ok "输出补丁适用版本" \
  || bad "适用版本字段不对：$(kv SI_TARGET_VERSION)"
[ "$(kv SI_TARGET_SERVER)" = server-v355 ] && ok "输出补丁适用 server" \
  || bad "适用 server 字段不对：$(kv SI_TARGET_SERVER)"
[ "$(kv DEX)" = "$BIN/server-v355.dex" ] && ok "输出 dex 路径" \
  || bad "dex 路径不对：$(kv DEX)"
[ "$(kv SIZE)" = "$(wc -c < "$T/original.bin" | tr -d ' ')" ] && ok "输出 dex 大小" \
  || bad "dex 大小不对：$(kv SIZE)"
[ "$(kv SHA)" = "$ORIG_SHA" ] && ok "输出 dex sha256" || bad "dex sha256 不对：$(kv SHA)"
[ "$(kv BACKUP_COUNT)" = 0 ] && ok "初始没有备份" \
  || bad "初始备份数不对：$(kv BACKUP_COUNT)"
[ "$(kv BACKUP_OK)" = 0 ] && ok "初始没有可用原版备份" \
  || bad "初始 BACKUP_OK 不对：$(kv BACKUP_OK)"
[ "$(kv PROMPTED)" = 0 ] && ok "初始未提示" || bad "初始 PROMPTED 不对：$(kv PROMPTED)"
run_capture status
has "$OUT" '可应用' && ok "status 显示可应用" || bad "status 没显示可应用：$OUT"

: > "$DATA/.patch_prompted"
run_capture check
[ "$(kv PROMPTED)" = 1 ] && ok "存在 .patch_prompted 时 PROMPTED=1" \
  || bad "PROMPTED 没读标记：$(kv PROMPTED)"
rm -f "$DATA/.patch_prompted"

SDK=37
SI_VER_OK=8.9.0.test
run_capture check
[ "$(kv STATE)" = original ] && ok "版本不匹配时仍按哈希判 original" \
  || bad "版本不匹配状态不对：$(kv STATE)"
[ "$(kv SI_MATCH)" = 0 ] && ok "版本不匹配时 SI_MATCH=0" \
  || bad "版本不匹配 SI_MATCH 不对：$(kv SI_MATCH)"
run_capture status
has "$OUT" '不适用' && ok "版本不匹配时 status 说不适用" \
  || bad "版本不匹配 status 不对：$OUT"
run_capture apply
[ "$RC" != 0 ] && ok "版本不匹配时 apply 拒绝" || bad "版本不匹配时 apply 没拒绝"
has "$ERR" '不适用' && ok "版本门禁拒绝原因明确" || bad "版本门禁原因不清：$ERR"
[ "$(target_sha)" = "$ORIG_SHA" ] && ok "版本门禁没动目标" || bad "版本门禁改动了目标"
reset_hooks

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
has "$OUT" '版本不匹配' && ok "status 显示版本不匹配" || bad "status 没显示版本不匹配：$OUT"
run_capture apply
[ "$RC" != 0 ] && ok "unknown apply 拒绝" || bad "unknown apply 没有拒绝"
has "$ERR" '已拒绝操作' && ok "unknown 拒绝原因明确" || bad "unknown 拒绝原因不清：$ERR"
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

# ---------- 9) chown 调用 ----------
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
run_capture apply
[ "$RC" = 0 ] && ok "注入 chown 后 apply 成功" || bad "注入 chown 后 apply 失败：$ERR"
[ -f "$T/fakebin/chown.log" ] && grep -q 'root:root' "$T/fakebin/chown.log" \
  && ok "apply 调用了 chown root:root" || bad "apply 没有调用 chown root:root"
CHOWN_OVERRIDE=

# ---------- 10) umask 022 下仍为 600；apply 成功 / no-op ----------
reset_hooks
clean_data
reset_original
run_capture_umask apply
[ "$RC" = 0 ] && ok "umask 022 下 apply 成功" || bad "umask 022 下 apply 失败：$ERR"
[ "$(target_sha)" = "$PATCH_SHA_EXPECT" ] && ok "目标已换成补丁 dex" \
  || bad "目标哈希不是补丁：$(target_sha)"
has "$OUT" '重新打开' && ok "成功提示重开 SI" || bad "成功提示缺重开 SI：$OUT"
[ "$(backup_count)" = 1 ] && ok "apply 留下 1 份备份" || bad "apply 备份数不对：$(backup_count)"
_bl=$(latest_backup)
[ -n "$_bl" ] && [ "$(sha_of "$_bl")" = "$ORIG_SHA" ] && ok "备份内容为原版" \
  || bad "备份内容不对：$_bl"
[ "$(stat -c %a "$BIN/server-v355.dex" 2>/dev/null)" = 600 ] && ok "目标权限 600" \
  || bad "目标权限不对：$(stat -c %a "$BIN/server-v355.dex" 2>/dev/null)"
[ "$(stat -c %a "$_bl" 2>/dev/null)" = 600 ] && ok "备份权限 600" \
  || bad "备份权限不对：$(stat -c %a "$_bl" 2>/dev/null)"
if [ "$(id -u 2>/dev/null)" = 0 ]; then
  [ "$(stat -c %U 2>/dev/null "$BIN/server-v355.dex")" = root ] && ok "目标属主 root" \
    || bad "目标属主不是 root"
fi
grep -q 'APPLY' "$DATA/patch.log" 2>/dev/null && ok "写了 apply 日志" \
  || bad "没有 apply 日志"
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

# ---------- 11) restore：最新备份坏、旧备份有效 ----------
printf 'corrupt newest backup\n' > "$DATA/patch-backup/server-v355.dex.99991231-235959"
chmod 600 "$DATA/patch-backup/server-v355.dex.99991231-235959"
run_capture check
[ "$(kv BACKUP_COUNT)" = 2 ] && ok "最新坏备份计入总数" \
  || bad "备份总数不对：$(kv BACKUP_COUNT)"
[ "$(kv BACKUP_OK)" = 1 ] && ok "最新坏但旧的有效时 BACKUP_OK=1" \
  || bad "BACKUP_OK 没跳过坏备份：$(kv BACKUP_OK)"
run_capture restore
[ "$RC" = 0 ] && ok "最新备份坏时 restore 仍成功" || bad "restore 没选旧的有效备份（$RC）：$ERR"
[ "$(target_sha)" = "$ORIG_SHA" ] && ok "restore 回到原版" || bad "restore 后哈希不对"

# ---------- 12) 备份全坏 ----------
run_capture apply
[ "$RC" = 0 ] && ok "为全坏备份用例重新应用" || bad "全坏备份用例准备失败：$ERR"
for _b in "$DATA/patch-backup/server-v355.dex".*; do
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

# ---------- 13) unknown + 有效备份 → 强制恢复 ----------
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

# ---------- 14) restore 当前副本与回滚 ----------
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

# ---------- 15) 已是原版 / 没有备份 ----------
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

# ---------- 16) 持锁后重查 ----------
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
cp "$ASSET_REAL" "$BIN/server-v355.dex"
chmod 600 "$BIN/server-v355.dex"
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

# ---------- 17) 并发锁 ----------
reset_hooks
clean_data
reset_original
cat > "$T/holder/si-patch.sh" <<'S'
#!/bin/sh
while :; do sleep 1; done
S
chmod 755 "$T/holder/si-patch.sh"
"$TEST_SH" "$T/holder/si-patch.sh" &
HOLDER=$!
_i=0
while [ "$_i" -lt 30 ]; do
  if tr '\0' ' ' < "/proc/$HOLDER/cmdline" 2>/dev/null | grep -q 'si-patch\.sh'; then break; fi
  sleep 0.1
  _i=$((_i + 1))
done
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

# ---------- 18) 卸载前恢复成功 ----------
M1=$T/un1/mod; D1=$T/un1/data; B1=$T/un1/bin
mkdir -p "$M1/scripts" "$D1/patch-backup" "$B1" || exit 1
cp module.prop "$M1/module.prop" || exit 1
cp "$PATCH" "$M1/scripts/si-patch.sh" || exit 1
chmod 755 "$M1/scripts/si-patch.sh"
cp "$ASSET_REAL" "$B1/server-v355.dex"
chmod 600 "$B1/server-v355.dex"
cp "$T/original.bin" "$D1/patch-backup/server-v355.dex.20260101-000000"
chmod 600 "$D1/patch-backup/server-v355.dex.20260101-000000"
SI_TEST=1 SI_MOD=$M1 SI_DATA=$D1 SI_PATCH_BIN=$B1 SI_PATCH_SDK=37 \
  SI_PATCH_VERSION=$SI_VER_OK SI_PATCH_ORIGINAL_SHA=$ORIG_SHA \
  "$TEST_SH" uninstall.sh >"$T/un1.out" 2>"$T/un1.err"
_rc=$?
[ "$_rc" = 0 ] && ok "卸载脚本成功退出" || bad "卸载脚本退出码 $_rc"
[ "$(sha_of "$B1/server-v355.dex")" = "$ORIG_SHA" ] && ok "卸载前已恢复原版 dex" \
  || bad "卸载前没有恢复原版 dex"
[ ! -d "$D1" ] && ok "恢复成功后数据目录已删除" || bad "恢复成功后数据目录还在"
has "$(cat "$T/un1.out" 2>/dev/null)" '已恢复 SI 原版' \
  && ok "卸载输出说明已恢复" || bad "卸载输出没说明恢复"

# ---------- 19) 卸载前恢复失败：保留备份 ----------
M2=$T/un2/mod; D2=$T/un2/data; B2=$T/un2/bin
mkdir -p "$M2/scripts" "$D2/patch-backup" "$B2" || exit 1
cp module.prop "$M2/module.prop" || exit 1
cp "$PATCH" "$M2/scripts/si-patch.sh" || exit 1
chmod 755 "$M2/scripts/si-patch.sh"
cp "$ASSET_REAL" "$B2/server-v355.dex"
chmod 600 "$B2/server-v355.dex"
printf 'corrupt backup\n' > "$D2/patch-backup/server-v355.dex.20260101-000000"
chmod 600 "$D2/patch-backup/server-v355.dex.20260101-000000"
SI_TEST=1 SI_MOD=$M2 SI_DATA=$D2 SI_PATCH_BIN=$B2 SI_PATCH_SDK=37 \
  SI_PATCH_VERSION=$SI_VER_OK SI_PATCH_ORIGINAL_SHA=$ORIG_SHA \
  "$TEST_SH" uninstall.sh >"$T/un2.out" 2>"$T/un2.err"
_rc=$?
[ "$_rc" = 0 ] && ok "恢复失败时卸载脚本仍成功退出" || bad "恢复失败时卸载退出码 $_rc"
[ -d "$D2" ] && ok "恢复失败时保留数据目录" || bad "恢复失败时数据目录被删"
[ -d "$D2/patch-backup" ] && ok "恢复失败时保留 patch-backup" \
  || bad "恢复失败时 patch-backup 被删"
[ "$(sha_of "$B2/server-v355.dex")" = "$PATCH_SHA_EXPECT" ] && ok "恢复失败时 dex 未被乱改" \
  || bad "恢复失败时 dex 被改"
has "$(cat "$T/un2.out" 2>/dev/null)" '补丁备份保留在' \
  && ok "卸载输出保留路径提示" || bad "卸载输出没有保留提示"

# ---------- 20) WebUI / action / build 接线（静态） ----------
grep -q 'P.patch = P.mod' webroot/index.html && ok "WebUI 指向 si-patch.sh" \
  || bad "WebUI 没接线 si-patch.sh"
grep -q '\.patch_prompted' webroot/index.html && ok "WebUI 使用 .patch_prompted" \
  || bad "WebUI 没使用 .patch_prompted"
for _id in patchCard patchHint patchActions btnPatchApply btnPatchRestore btnPatchForce \
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
grep -q "act === 'patch-apply') { armPatchAction('apply'); }" webroot/index.html \
  && ok "banner 应用按钮也走两步确认" || bad "banner 应用按钮直接执行"
grep -q "act === 'patch-confirm-go') { confirmPatchAction(); }" webroot/index.html \
  && ok "banner 确认按钮执行" || bad "banner 确认按钮没接线"
grep -q 'p.targetVersion' webroot/index.html && grep -q 'p.targetServer' webroot/index.html \
  && grep -q '仅适用于' webroot/index.html && ok "确认框显示 SI 版本与适用范围" \
  || bad "确认框缺少 SI 版本/适用范围"
grep -q 'state.patchConfirm' webroot/index.html && ok "WebUI 有确认状态" \
  || bad "WebUI 没有确认状态"
grep -q 'patchError' webroot/index.html && ok "WebUI 有补丁错误状态" \
  || bad "WebUI 没有补丁错误状态"
_run_refs=$(grep -c 'runPatchAction' webroot/index.html)
[ "$_run_refs" = 2 ] && ok "runPatchAction 只在确认后调用（2 处）" \
  || bad "runPatchAction 调用点不对：$_run_refs"
grep -q '已应用，可恢复原版' webroot/index.html && ok "WebUI 已应用文案" \
  || bad "WebUI 缺少已应用文案"
grep -q '版本不匹配，未动' webroot/index.html && ok "WebUI 版本不匹配文案" \
  || bad "WebUI 缺少版本不匹配文案"
grep -q "SI_MATCH" webroot/index.html && grep -q "BACKUP_OK" webroot/index.html \
  && ok "WebUI 读取版本门禁与有效备份字段" || bad "WebUI 没读新字段"
grep -q 'si-patch\.sh" status' action.sh && ok "action.sh 显示补丁状态" \
  || bad "action.sh 没有补丁状态"
grep -q 'si-patch\.sh" apply' action.sh && bad "action.sh 会自动 apply" \
  || ok "action.sh 不自动 apply"
grep -q 'assets/server-v355.dex' tools/build.sh && ok "构建脚本包含补丁资产" \
  || bad "构建脚本没有补丁资产"
grep -q '48ff195e' tools/build.sh && ok "构建脚本校验补丁 sha" \
  || bad "构建脚本没有校验补丁 sha"
grep -q 'siPatchVersion' tools/build.sh && ok "构建脚本校验适用版本字段" \
  || bad "构建脚本没有校验适用版本字段"
[ -f CHANGELOG.md ] && grep -q '^## 1.5.0' CHANGELOG.md \
  && ok "CHANGELOG 只列出 1.5.0" || bad "CHANGELOG 缺少 1.5.0"
grep -q 'raw/main/CHANGELOG.md' update.json && ok "update.json 指向 CHANGELOG" \
  || bad "update.json 没指向 CHANGELOG"
grep -q 'CHANGELOG.md' tools/build.sh && ok "构建脚本打包 CHANGELOG" \
  || bad "构建脚本没有打包 CHANGELOG"

echo
[ "$fail" = 0 ] && { echo "patch.test: PASS"; exit 0; }
echo "patch.test: FAIL"; exit 1
