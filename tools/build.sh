#!/system/bin/sh
# 打包模块 zip（在仓库根目录执行）：sh tools/build.sh
#
# 产物 si-mount-fix.zip；所有条目固定时间戳/权限，同一份源码打出的包一致。
# 打包前会先跑工具链自检与测试；任何一步失败都会删掉半成品 zip 并非 0 退出。
#
# 环境：
#   SKIP_TESTS=1   跳过构建前的 tools/run-tests.sh（CI 里测试已单独跑过时用）
#   TMPDIR         测试临时目录；未设置时自动挑可写目录（Android 上 /tmp 通常不存在）
#   SI_BUILD_SH    语法检查用的 shell（默认 sh；CI 可用 mksh）
set -eu
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." || exit 1
OUT=si-mount-fix.zip
US=META-INF/com/google/android/updater-script
UB=META-INF/com/google/android/update-binary
REPO_URL=https://github.com/lukka-hub/si-mount-fix
UPDATE_JSON_URL=$REPO_URL/raw/main/update.json
# 补丁 main.dex：1.6.0 只分发 A17 资产，只替换 zygisk-storage-isolation 的 main.dex。
A17_ASSET=assets/main-a17.dex
A17_SHA=3eafcb101fe7ae9eaa7e5614a55275391c37d3b012c4d4c814276b0215700fcc
A17_SIZE=88808

check_asset() {
  _asset=$1
  _want_sha=$2
  _want_size=$3
  _label=$4
  [ -f "$_asset" ] || die "缺少补丁资产：$_asset（$_label）"
  _size=$(wc -c < "$_asset" | tr -d '[:space:]')
  [ "$_size" = "$_want_size" ] || die "$_label 资产大小不对：$_size B（应为 $_want_size B）"
  if command -v sha256sum >/dev/null 2>&1; then
    _sha=$(sha256sum "$_asset" | awk '{print $1}')
  else
    _sha=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$_asset")
  fi
  [ "$_sha" = "$_want_sha" ] || die "$_label 资产 sha256 不匹配：实际 $_sha，应为 $_want_sha（不要修改 dex 内容）"
  say "$_label 资产：$_asset（$_size B，sha256 $_sha）"
}

say() { printf '%s\n' "$*"; }
die() { printf 'build: %s\n' "$*" >&2; exit 1; }

# 失败/中断时删除半成品 zip（只删自己正在写的产物，不动已存在的完整包以外的文件）
HAVE_OUT=0
cleanup() {
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$HAVE_OUT" = 1 ]; then
    rm -f "$OUT"
    printf 'build: 构建失败，已删除半成品 %s\n' "$OUT" >&2
  fi
  exit "$rc"
}
on_signal() {
  rm -f "$OUT"
  trap - EXIT
  printf 'build: 被中断，已删除半成品 %s\n' "$OUT" >&2
  exit 130
}
trap cleanup EXIT
trap on_signal INT TERM HUP
# 构建失败必须不留 zip：先删旧产物，成功时才重新生成。
rm -f "$OUT"

prop_get() { sed -n "s/^$1=//p" module.prop 2>/dev/null | head -1; }

# ---------- 1) module.prop 基本字段 ----------
[ -f module.prop ] || die 'module.prop 不存在'
PROP_ID=$(prop_get id)
PROP_NAME=$(prop_get name)
V_PROP=$(prop_get version)
V_CODE=$(prop_get versionCode)
[ "$PROP_ID" = si-mount-fix ] || die "module.prop id 必须是 si-mount-fix：[$PROP_ID]"
[ -n "$PROP_NAME" ] || die 'module.prop 缺少 name'
[ -n "$V_PROP" ] || die 'module.prop 缺少 version'
[ -n "$V_CODE" ] || die 'module.prop 缺少 versionCode'
[ -n "$(prop_get description)" ] || die 'module.prop 缺少 description'
[ -n "$(prop_get author)" ] || die 'module.prop 缺少 author'
# 补丁适用版本由 module.prop 单一提供，脚本/WebUI 不写版本字面量。
[ -n "$(prop_get siPatchModule)" ] || die 'module.prop 缺少 siPatchModule（补丁适用的 Zygisk 模块）'
[ "$(prop_get siPatchModule)" = zygisk-storage-isolation ] \
  || die "siPatchModule 应为 zygisk-storage-isolation，当前：$(prop_get siPatchModule)"
[ -n "$(prop_get siPatchTarget)" ] || die 'module.prop 缺少 siPatchTarget（补丁目标文件名）'
[ -n "$(prop_get siPatchVersion)" ] || die 'module.prop 缺少 siPatchVersion（补丁适用模块版本）'
[ -n "$(prop_get siPatchVersionCode)" ] || die 'module.prop 缺少 siPatchVersionCode（补丁适用模块 versionCode）'

# ---------- 2) version ↔ versionCode 一致性（三段补零成四位：v1.6.0 ↔ 1600；四段：v1.5.7.1 ↔ 1571）----------
VERSION=${V_PROP#v}
case "$VERSION" in
  *.*.*) ;;
  *) die "version 必须是 v<major>.<minor>.<patch>[.<micro>]：$V_PROP" ;;
esac
V_MAJOR=${VERSION%%.*}
V_REST=${VERSION#*.}
V_MINOR=${V_REST%%.*}
V_TAIL=${V_REST#*.}
case "$V_TAIL" in
  *.*)
    V_PATCH=${V_TAIL%%.*}
    V_MICRO=${V_TAIL#*.}
    case "$V_MICRO" in
      ''|*[!0-9]*) die "version 各段必须是数字：$V_PROP" ;;
      *.*) die "version 最多四段：$V_PROP" ;;
    esac ;;
  *)
    V_PATCH=$V_TAIL
    V_MICRO= ;;
esac
case "$V_MAJOR$V_MINOR$V_PATCH$V_MICRO" in
  ''|*[!0-9]*) die "version 各段必须是数字：$V_PROP" ;;
esac
[ "$V_MINOR" -le 9 ] && [ "$V_PATCH" -le 9 ] \
  || die "versionCode 规则要求 minor/patch <= 9：$V_PROP"
if [ -n "$V_MICRO" ]; then
  [ "$V_MICRO" -le 9 ] || die "versionCode 规则要求 micro <= 9：$V_PROP"
  V_CODE_EXPECT=$((V_MAJOR * 1000 + V_MINOR * 100 + V_PATCH * 10 + V_MICRO))
else
  V_CODE_EXPECT=$((V_MAJOR * 1000 + V_MINOR * 100 + V_PATCH * 10))
fi
case "$V_CODE" in
  ''|*[!0-9]*) die "versionCode 必须是数字：[$V_CODE]" ;;
esac
[ "$V_CODE" = "$V_CODE_EXPECT" ] \
  || die "versionCode 与 version 不一致：$V_PROP 应为 $V_CODE_EXPECT，module.prop 写的是 $V_CODE"
say "版本：$V_PROP / versionCode=$V_CODE（一致）"

# ---------- 3) updateJson / update.json ----------
PROP_UJ=$(prop_get updateJson)
[ -n "$PROP_UJ" ] || die 'module.prop 缺少 updateJson（Magisk 更新检查需要）'
case "$PROP_UJ" in
  https://*) ;;
  *) die "updateJson 必须是绝对 URL（Magisk 联网拉取，相对路径会失败）：[$PROP_UJ]" ;;
esac
[ "$PROP_UJ" = "$UPDATE_JSON_URL" ] \
  || die "updateJson 应指向 $UPDATE_JSON_URL，当前：[$PROP_UJ]"
[ -f update.json ] || die 'update.json 不存在（updateJson 指向的文件要随仓库发布）'
python3 - "$V_PROP" "$V_CODE" "$REPO_URL" <<'PY' || die 'update.json 校验失败'
import json, sys

v_prop, v_code, repo = sys.argv[1], sys.argv[2], sys.argv[3].rstrip('/')
try:
    with open('update.json', encoding='utf-8') as f:
        d = json.load(f)
except Exception as e:
    raise SystemExit('update.json 不是合法 JSON：%s' % e)

errs = []
if d.get('version') != v_prop:
    errs.append('version 应为 %r，实际 %r' % (v_prop, d.get('version')))
vc = d.get('versionCode')
if str(vc) != v_code:
    errs.append('versionCode 应为 %r，实际 %r' % (v_code, vc))
want = '%s/releases/download/%s/si-mount-fix.zip' % (repo, v_prop)
if d.get('zipUrl') != want:
    errs.append('zipUrl 应为 %r，实际 %r' % (want, d.get('zipUrl')))
changelog = d.get('changelog')
if not isinstance(changelog, str) or not changelog.startswith('https://'):
    errs.append('changelog 必须是 https URL')
if errs:
    raise SystemExit('update.json：' + '；'.join(errs))
print('update.json：版本/versionCode/zipUrl 与 module.prop 一致')
PY
say "updateJson：$PROP_UJ"

# ---------- 3b) 自建补丁资产：A17 dex 内容不能变，sha256/大小必须与发布说明一致 ----------
PATCH_FOR_TARGET=$(prop_get siPatchTarget)
[ "$PATCH_FOR_TARGET" = main.dex ] \
  || die "siPatchTarget 应为 main.dex，当前：$PATCH_FOR_TARGET"
check_asset "$A17_ASSET" "$A17_SHA" "$A17_SIZE" A17

# ---------- 4) updater-script 首行必须是 #MAGISK ----------
[ -f "$US" ] || die "$US 不存在"
[ "$(head -1 "$US")" = '#MAGISK' ] || die "$US 首行必须是 #MAGISK（Magisk/KSU 安装器入口标记）"
_us_lines=$(grep -c '' "$US" 2>/dev/null || true)
[ "$_us_lines" = 1 ] || die "$US 只能是单独一行 #MAGISK，当前 $_us_lines 行"
[ -f "$UB" ] || die "$UB 不存在"

# ---------- 5) 源码可执行位（不静默 chmod；zip 内仍归一 755）----------
for f in service.sh action.sh uninstall.sh "$UB"; do
  [ -f "$f" ] || die "缺少 $f"
  [ -x "$f" ] || die "源码缺少可执行位：$f（git update-index --chmod=+x $f）"
done
for f in scripts/*.sh; do
  [ -f "$f" ] || continue
  [ -x "$f" ] || die "源码缺少可执行位：$f（git update-index --chmod=+x $f）"
done

# ---------- 6) 语法检查 ----------
# 语法检查尽量用真机同款 shell：SI_BUILD_SH > SI_TEST_SH > sh，不可执行则回退。
BUILD_SH=${SI_BUILD_SH:-${SI_TEST_SH:-sh}}
if ! { command -v "$BUILD_SH" >/dev/null 2>&1 && "$BUILD_SH" -c ':' >/dev/null 2>&1; }; then
  BUILD_SH=$(command -v mksh 2>/dev/null)
fi
if [ -z "$BUILD_SH" ] || ! { command -v "$BUILD_SH" >/dev/null 2>&1 && "$BUILD_SH" -c ':' >/dev/null 2>&1; }; then
  BUILD_SH=$(command -v sh 2>/dev/null)
fi
[ -n "$BUILD_SH" ] || die '找不到可用的 sh 做语法检查（可用 SI_BUILD_SH=... 指定）'
for f in *.sh scripts/*.sh "$UB"; do
  "$BUILD_SH" -n "$f" || die "语法错误：$f"
done
say "语法检查通过（$BUILD_SH -n）"

# ---------- 7) 版本号只有一个来源：脚本/webroot 不能写死任何版本号 ----------
# 例外：A15/A16 的“1.6.0 仅支持 A17、待 1.6.1”提示必须写死版本，避免用户误以为当前版本
# 已支持 A15/A16；只放行这两段提示文案，其它版本号仍必须读 module.prop。
SCAN="service.sh action.sh uninstall.sh webroot/index.html"
for f in scripts/*.sh; do
  [ -f "$f" ] && SCAN="$SCAN $f"
done
[ -f scripts/si-config.awk ] && SCAN="$SCAN scripts/si-config.awk"
bad=$(grep -nE 'v?[0-9]+\.[0-9]+\.[0-9]+' $SCAN 2>/dev/null \
  | grep -vE '1\.6\.0 仅支持|A15/A16 待 1\.6\.1' || true)
[ -z "$bad" ] || die "脚本/webroot 里写死了版本号（应读 module.prop）：
$bad"
say "版本号来源检查通过（脚本/webroot 无版本字面量，A15/A16 提示除外）"

# ---------- 8) 运行期残留与包内白名单 ----------
for f in webroot/snapshot.js webroot/snapshot.js.* webroot/*.tmp; do
  [ -e "$f" ] && die "webroot 有守护运行期残留：$f（先 rm -f webroot/snapshot.js* webroot/*.tmp）"
done

FILES="module.prop README.md CHANGELOG.md LICENSE service.sh action.sh uninstall.sh"
FILES="$FILES scripts/si-mount-eventd.sh scripts/fix-si-mounts.sh scripts/supervisor.sh"
FILES="$FILES scripts/restart.sh scripts/list-apps.sh scripts/result.sh scripts/si-patch.sh"
FILES="$FILES webroot/index.html $UB $US $A17_ASSET"
for f in $FILES; do
  [ -f "$f" ] || die "缺少必需的打包文件：$f"
done
# 新增的 si-config.awk 由脚本引用决定是否必须存在：引用即要求存在并进包。
if grep -q 'si-config\.awk' scripts/*.sh 2>/dev/null; then
  [ -f scripts/si-config.awk ] || die '脚本引用了 scripts/si-config.awk，但文件不存在'
  FILES="$FILES scripts/si-config.awk"
fi
# 白名单之外的文件一律拒绝（含 webroot/snapshot.js.bak 之类的变体）。
for f in $(find scripts webroot META-INF assets -type f 2>/dev/null | sort); do
  case " $FILES " in
    *" $f "*) ;;
    *) die "白名单之外的文件不能进包：$f（运行期残留请删除）" ;;
  esac
done
say "包内白名单检查通过（$(printf '%s\n' $FILES | wc -l | tr -d ' ') 个文件）"

# ---------- 9) 构建前测试（工具链自检 + 回归）----------
if [ "${SKIP_TESTS:-0}" = 1 ]; then
  say '跳过测试（SKIP_TESTS=1）'
else
  TEST_TMPDIR=${TMPDIR:-}
  if [ -z "$TEST_TMPDIR" ]; then
    if [ -d /tmp ] && [ -w /tmp ]; then
      TEST_TMPDIR=/tmp
    elif [ -d /data/local/tmp ] && [ -w /data/local/tmp ]; then
      TEST_TMPDIR=/data/local/tmp
    else
      TEST_TMPDIR=.
    fi
  fi
  [ -d "$TEST_TMPDIR" ] || die "临时目录不可用：$TEST_TMPDIR（用 TMPDIR=... 指定）"
  say "== 构建前测试（TMPDIR=$TEST_TMPDIR）"
  TMPDIR=$TEST_TMPDIR SKIP_SLOW=${SKIP_SLOW:-0} "$BUILD_SH" tools/run-tests.sh \
    || die '测试失败，不打包（可用 SKIP_TESTS=1 跳过）'
fi

# ---------- 10) 打包：白名单、固定时间戳、脚本 755 / 其它 644 ----------
HAVE_OUT=1
python3 - "$OUT" "$FILES" <<'PY'
import os, sys, zipfile

out = sys.argv[1]
files = sorted(set(sys.argv[2].split()))
if not files:
    raise SystemExit('没有可打包的文件')

FIXED = (1980, 1, 1, 0, 0, 0)
dirs = []
for f in files:
    parts = f.split('/')[:-1]
    for i in range(1, len(parts) + 1):
        d = '/'.join(parts[:i])
        if d not in dirs:
            dirs.append(d)
dirs.sort()

def mode_for(path):
    if path.endswith('.sh') or path.endswith('update-binary'):
        return 0o100755
    return 0o100644

def add(z, path, arcname, is_dir=False):
    zi = zipfile.ZipInfo(arcname + ('/' if is_dir else ''), FIXED)
    zi.external_attr = ((0o40755 if is_dir else mode_for(path)) << 16) | (0x10 if is_dir else 0)
    zi.compress_type = zipfile.ZIP_STORED if is_dir else zipfile.ZIP_DEFLATED
    data = b'' if is_dir else open(path, 'rb').read()
    z.writestr(zi, data)

if os.path.exists(out):
    os.remove(out)

with zipfile.ZipFile(out, 'w') as z:
    for d in dirs:
        add(z, d, d, is_dir=True)
    for f in files:
        add(z, f, f)

print('built %s %d bytes' % (out, os.path.getsize(out)))
PY

# ---------- 11) 自检：条目集合、权限、关键内容 ----------
python3 - "$OUT" "$V_PROP" "$V_CODE" "$FILES" "$A17_ASSET" "$A17_SHA" <<'PY' || die 'zip 自检失败'
import hashlib, sys, zipfile

z = zipfile.ZipFile(sys.argv[1])
v_prop, v_code = sys.argv[2], sys.argv[3]
expected = sorted(sys.argv[4].split())
a17_asset, a17_sha = sys.argv[5], sys.argv[6]
names = z.namelist()
files = sorted(n for n in names if not n.endswith('/'))
dirs = sorted(n for n in names if n.endswith('/'))

if files != expected:
    extra = [n for n in files if n not in expected]
    miss = [n for n in expected if n not in files]
    raise SystemExit('包内条目与白名单不一致；多出=%s 缺少=%s' % (extra, miss))

leak = [n for n in files if n.startswith('webroot/snapshot.js') or n.endswith('.tmp')
        or n.startswith('tools/') or n.startswith('docs/') or n.endswith('.test.sh')]
if leak:
    raise SystemExit('运行期/开发文件被错误打包: ' + ', '.join(leak))
if 'LICENSE' not in files:
    raise SystemExit('LICENSE 没有进包')
if 'update.json' in files:
    raise SystemExit('update.json 是发布用的仓库文件，不应进 zip')

bad = []
for n in files:
    want = 0o755 if (n.endswith('.sh') or n.endswith('update-binary')) else 0o644
    m = (z.getinfo(n).external_attr >> 16) & 0o777
    if m != want:
        bad.append('%s=%o(应为%o)' % (n, m, want))
if bad:
    raise SystemExit('权限不对: ' + ', '.join(bad))

prop = z.read('module.prop').decode('utf-8')
for want in ('version=' + v_prop, 'versionCode=' + v_code, 'updateJson=https://'):
    if want not in prop:
        raise SystemExit('包内 module.prop 缺少/不一致：' + want)

up = z.read('META-INF/com/google/android/updater-script').decode('utf-8')
if up.splitlines()[:1] != ['#MAGISK']:
    raise SystemExit('包内 updater-script 首行不是 #MAGISK')

if 'webroot/index.html' not in files:
    raise SystemExit('缺少 webroot/index.html')

if a17_asset not in files:
    raise SystemExit('补丁资产没有进包：' + a17_asset)
if hashlib.sha256(z.read(a17_asset)).hexdigest() != a17_sha:
    raise SystemExit('包内补丁资产 sha256 与构建前校验值不一致：' + a17_asset)

print('zip 自检通过：%d 个文件 + %d 个目录，脚本 755 / 其它 644' % (len(files), len(dirs)))
PY

if command -v sha256sum >/dev/null 2>&1; then sha256sum "$OUT"; fi
say "built: $OUT  ($V_PROP / $V_CODE)"
