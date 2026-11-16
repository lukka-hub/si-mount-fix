#!/system/bin/sh
# 打包模块 zip（在仓库根目录执行）：sh tools/build.sh
# 产出 si-mount-fix.zip；所有条目固定时间戳/权限，同一份源码打出的包一致。
set -e
cd "$(dirname "$0")/.."
OUT=si-mount-fix.zip

V_PROP=$(sed -n 's/^version=v//p' module.prop | head -1)
V_CODE=$(sed -n 's/^versionCode=//p' module.prop | head -1)
[ -n "$V_PROP" ] || { echo "module.prop 缺少 version" >&2; exit 1; }
[ -n "$V_CODE" ] || { echo "module.prop 缺少 versionCode" >&2; exit 1; }
grep -q '^description=' module.prop || { echo "module.prop 缺少 description" >&2; exit 1; }

# 1) 运行期生成的文件绝不能进包（含守护写的 snapshot.js.<pid> 残留）
rm -f webroot/snapshot.js webroot/snapshot.js.* 2>/dev/null || true

# 2) 权限归一（源码目录里可能是 0600）
chmod 755 *.sh scripts/*.sh META-INF/com/google/android/update-binary 2>/dev/null || true
chmod 644 module.prop README.md META-INF/com/google/android/updater-script webroot/index.html 2>/dev/null || true

# 3) 语法检查
for f in *.sh scripts/*.sh; do
  sh -n "$f" || { echo "语法错误：$f" >&2; exit 1; }
done

# 4) 版本号只有一个来源：脚本里不能出现写死的版本号
bad=$(grep -rn "$V_PROP" service.sh action.sh uninstall.sh scripts webroot 2>/dev/null || true)
[ -z "$bad" ] || { echo "版本号被写死了（应读 module.prop）：" >&2; echo "$bad" >&2; exit 1; }

# 5) 打包：固定 1980-01-01 时间戳，脚本 755 / 其它 644
python3 - "$OUT" <<'PY'
import os, sys, zipfile

out = sys.argv[1]
items = ['module.prop', 'service.sh', 'uninstall.sh', 'action.sh', 'README.md',
         'scripts', 'webroot', 'META-INF']
FIXED = (1980, 1, 1, 0, 0, 0)

def mode_for(path):
    if path.endswith('.sh') or path.endswith('update-binary'):
        return 0o100755
    return 0o100644

def add(z, path, arcname, is_dir=False):
    zi = zipfile.ZipInfo(arcname.rstrip('/') + ('/' if is_dir else ''), FIXED)
    zi.external_attr = ((0o40755 if is_dir else mode_for(path)) << 16) | (0x10 if is_dir else 0)
    zi.compress_type = zipfile.ZIP_STORED if is_dir else zipfile.ZIP_DEFLATED
    z.writestr(zi, b'' if is_dir else open(path, 'rb').read())

if os.path.exists(out):
    os.remove(out)

seen = set()
with zipfile.ZipFile(out, 'w') as z:
    for it in items:
        if not os.path.isdir(it):
            add(z, it, it)
            continue
        add(z, it, it, is_dir=True)
        for root, dirs, files in os.walk(it):
            dirs.sort()
            for d in sorted(dirs):
                p = os.path.join(root, d)
                if p in seen:
                    continue
                seen.add(p)
                add(z, p, p, is_dir=True)
            for f in sorted(files):
                p = os.path.join(root, f)
                add(z, p, p)

print('built', out, os.path.getsize(out), 'bytes')
PY

# 6) 自检
python3 - "$OUT" "$V_PROP" "$V_CODE" <<'PY'
import sys, zipfile

z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
need = ['META-INF/com/google/android/update-binary', 'META-INF/com/google/android/updater-script',
        'module.prop', 'service.sh', 'action.sh', 'uninstall.sh', 'webroot/index.html',
        'scripts/si-mount-eventd.sh', 'scripts/fix-si-mounts.sh',
        'scripts/supervisor.sh', 'scripts/restart.sh', 'scripts/list-apps.sh']
miss = [n for n in need if n not in names]
if miss:
    raise SystemExit('缺少文件: ' + ', '.join(miss))

# 运行期文件一个都不能进包
leak = [n for n in names if n.startswith('webroot/snapshot.js') or n.endswith('.tmp')]
if leak:
    raise SystemExit('运行期文件被错误打包: ' + ', '.join(leak))
if any(n.startswith('tools/') or n.endswith('/si-mount-fix.zip') for n in names):
    raise SystemExit('开发文件被错误打包')

bad = []
for n in names:
    if n.endswith('/'):
        continue
    if not (n.endswith('.sh') or n.endswith('update-binary')):
        continue
    m = (z.getinfo(n).external_attr >> 16) & 0o777
    if m != 0o755:
        bad.append('%s=%o' % (n, m))
if bad:
    raise SystemExit('权限不对: ' + ', '.join(bad))

prop = z.read('module.prop').decode('utf-8')
if ('version=v' + sys.argv[2]) not in prop:
    raise SystemExit('module.prop version 与期望不一致')
if ('versionCode=' + sys.argv[3]) not in prop:
    raise SystemExit('module.prop versionCode 与期望不一致')

print('zip 自检通过：%d 个条目，无运行期文件，脚本权限 755' % len(names))
PY

command -v sha256sum >/dev/null 2>&1 && sha256sum "$OUT"
echo "built: $OUT  (v$V_PROP / $V_CODE)"
