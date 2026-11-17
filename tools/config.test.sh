#!/system/bin/sh
# 配置解析回归：统一解析器 scripts/si-config.awk + fix 的 fail-closed 行为。
# 覆盖：真实 schema（顶层 packages + 嵌套 mount_dirs）、多行/空格 JSON、
#       enabled 缺省/显式 false、未知模板、含空格目录、截断 JSON、未知 schema。
# 用法：sh tools/config.test.sh
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1
FIX=scripts/fix-si-mounts.sh

# 测试壳：优先显式 SI_TEST_SH，其次 Android /system/bin/sh，最后 mksh/sh。
if [ -n "$SI_TEST_SH" ]; then SH=$SI_TEST_SH
elif [ -x /system/bin/sh ]; then SH=/system/bin/sh
elif command -v mksh >/dev/null 2>&1; then SH=mksh
else SH=sh
fi

T=${TMPDIR:-/tmp}/si-config-test.$$
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/proc/self" "$T/proc/123" "$T/data" "$T/dataroot" "$T/src" "$T/bin" || exit 1
P=$T/proc

cat > "$P/self/mountinfo" <<'M'
100 1 0:50 / / rw - ext4 /dev/root rw
101 100 0:50 / /mnt/user/0/emulated rw - fuse /dev/fuse rw
102 100 0:50 / /storage/emulated rw - fuse /dev/fuse rw
M

# 沙箱根 + 一条 DCIM 挂载；目标目录故意保持自然状态（DCIM 缺失场景由各用例决定）。
write_mountinfo() {   # $1=pkg
  cat > "$P/123/mountinfo" <<M
200 1 0:50 /0/Android/data/$1/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
M
}

cat > "$T/bin/ps" <<'S'
#!/bin/sh
printf '  PID   UID     ELAPSED ARGS\n  123     0    01:00 com.victim\n'
S
cat > "$T/bin/nsenter" <<'S'
#!/bin/sh
exit 1
S
chmod 755 "$T/bin/ps" "$T/bin/nsenter"

# 源目录：应用沙箱里看到 DCIM；宿主机 FUSE 层也有 DCIM。
mkdir -p "$T/dataroot/media/0/Android/data/com.victim/sdcard/DCIM" "$T/src/0/DCIM"
mkdir -p "$T/dataroot/media/0/Android/data/com.victim" "$T/src/0/Android/data/com.victim"

write_mountinfo com.victim

run() {   # $1=conf 文件；输出 stdout+stderr
  SI_TEST=1 SI_PROC=$P SI_CONF=$1 SI_DATA=$T/data \
    SI_TEST_DATA=$T/dataroot SI_TEST_SRC=$T/src SI_MIN_AGE=5 \
    PATH=$T/bin:$PATH "$SH" "$FIX" -n -v 2>&1
}

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }

# 1) 真实 schema：顶层 packages + mount_dirs 对象内嵌 template_ids
cat > "$T/c1.json" <<'J'
{"mount_dirs_templates":[{"id":"t1","list":["DCIM"]}],"packages":[{"package_name":"com.victim","enabled":true,"mount_dirs":{"flags":1,"template_ids":["t1"]}}]}
J
out=$(run "$T/c1.json")
case "$out" in
  *"允许: com.victim -> DCIM"*) ok "packages + 嵌套 mount_dirs 能解析出模板目录" ;;
  *) bad "真实 schema 没解析出目录：$out" ;;
esac
case "$out" in
  *"RESULT checked=1 broken="*) ok "进程被正常检查（checked=1）" ;;
  *) bad "checked 不为 1：$out" ;;
esac

# 2) 多行 + 冒号/逗号周围空白：与压缩 JSON 结果一致
cat > "$T/c2.json" <<'J'
{
  "mount_dirs_templates": [
    { "id": "t1", "list": [ "DCIM", "Pictures" ] }
  ],
  "packages": [
    {
      "package_name": "com.victim",
      "enabled": true,
      "mount_dirs": { "flags": 1, "template_ids": [ "t1" ] }
    }
  ]
}
J
out2=$(run "$T/c2.json")
case "$out2" in
  *"允许: com.victim -> DCIM Pictures"*) ok "多行/空白 JSON 输出正常" ;;
  *) bad "多行 JSON 解析失败：$out2" ;;
esac

# 3) enabled 缺省：保持旧实现的“缺省启用”，避免升级后突然不修
cat > "$T/c3.json" <<'J'
{"mount_dirs_templates":[{"id":"t1","list":["DCIM"]}],"packages":[{"package_name":"com.victim","mount_dirs":{"template_ids":["t1"]}}]}
J
out3=$(run "$T/c3.json")
case "$out3" in
  *"允许: com.victim -> DCIM"*) ok "enabled 缺省时保持启用（兼容旧行为）" ;;
  *) bad "enabled 缺省被误判停用：$out3" ;;
esac

# 4) 显式 false（带空格）：必须跳过
cat > "$T/c4.json" <<'J'
{"mount_dirs_templates":[{"id":"t1","list":["DCIM"]}],"packages":[{"package_name":"com.victim","enabled" : false,"mount_dirs":{"template_ids":["t1"]}}]}
J
out4=$(run "$T/c4.json")
case "$out4" in
  *skipped=*disabled*) ok "显式 enabled:false（带空格）被跳过" ;;
  *) bad "enabled:false 没有被跳过：$out4" ;;
esac
case "$out4" in
  *"允许: com.victim"*) bad "停用应用仍尝试修复：$out4" ;;
  *) ok "停用应用没有修复动作" ;;
esac

# 5) 未知模板 id：不能猜目录，打 skipped=template
cat > "$T/c5.json" <<'J'
{"packages":[{"package_name":"com.victim","enabled":true,"mount_dirs":{"template_ids":["NO_SUCH_TEMPLATE"]}}]}
J
out5=$(run "$T/c5.json")
case "$out5" in
  *skipped=*template*) ok "未知模板 id 打 skipped=template" ;;
  *) bad "未知模板没有标签：$out5" ;;
esac
case "$out5" in
  *"允许: com.victim -> "*) bad "未知模板仍拼出空/错目录：$out5" ;;
  *) ok "未知模板没有产生挂载目标" ;;
esac

# 6) 目录含空格：跳过该目录，不猜 target
cat > "$T/c6.json" <<'J'
{"mount_dirs_templates":[{"id":"t1","list":["DCIM"]}],"packages":[{"package_name":"com.victim","enabled":true,"mount_dirs":{"template_ids":["t1"],"custom_dirs":["My Files"]}}]}
J
out6=$(run "$T/c6.json")
case "$out6" in
  *skipped=*dir_space*) ok "含空格目录打 skipped=dir_space" ;;
  *) bad "含空格目录没有标签：$out6" ;;
esac
case "$out6" in
  *"允许: com.victim -> DCIM"*) ok "含空格目录被跳过，其余目录仍修" ;;
  *) bad "含空格目录影响了正常目录：$out6" ;;
esac

# 7) 截断 JSON：必须 error=config，不能静默空转
printf '%s' '{"apps":[{"package_name":"com.victim","enabled":true}' > "$T/c7.json"
out7=$(run "$T/c7.json")
case "$out7" in
  *error=config*) ok "截断 JSON 报 error=config" ;;
  *) bad "截断 JSON 未报错：$out7" ;;
esac

# 8) 未知 schema：不能静默空转，应 error=config
printf '%s' '{"misc":{"version":1}}' > "$T/c8.json"
out8=$(run "$T/c8.json")
case "$out8" in
  *error=config*) ok "未知 schema 报 error=config" ;;
  *) bad "未知 schema 未报错：$out8" ;;
esac

# 9) 手动执行（action/WebUI）不传 SI_MIN_AGE 时，fix 自己读 config.conf
mkdir -p "$T/data2"
printf 'MIN_AGE=120\n' > "$T/data2/config.conf"
out9=$(SI_TEST=1 SI_PROC=$P SI_CONF=$T/c1.json SI_DATA=$T/data2 \
  SI_TEST_DATA=$T/dataroot SI_TEST_SRC=$T/src \
  PATH=$T/bin:$PATH "$SH" "$FIX" -n 2>&1)
case "$out9" in
  *young=1*) ok "未传 SI_MIN_AGE 时按 config.conf 的 120s 判 young" ;;
  *) bad "config.conf 的 MIN_AGE 未生效：$out9" ;;
esac

# 10) 模板里的目录本身含空格：解析器输出 W 行，fix 必须汇总成 skipped（不能静默）
cat > "$T/c10.json" <<'J'
{"mount_dirs_templates":[{"id":"t1","list":["DCIM","My Files"]}],"packages":[{"package_name":"com.victim","enabled":true,"mount_dirs":{"template_ids":["t1"]}}]}
J
out10=$(run "$T/c10.json")
case "$out10" in
  *skipped=*dir_space*) ok "模板内的含空格目录打 skipped=dir_space（W 行被消费）" ;;
  *) bad "模板内的含空格目录没有标签：$out10" ;;
esac
case "$out10" in
  *"允许: com.victim -> DCIM"*) ok "模板内的坏目录不影响其余目录" ;;
  *) bad "模板内的坏目录影响了正常目录：$out10" ;;
esac

# 11) package_name 非法（换行/引号）：必须 fail-closed，不能破坏行协议或 list-apps 的 JSON
#     用 printf 写 JSON 转义序列（\n、\"），避免 heredoc 把转义写成真实字符
{
  printf '%s' '{"mount_dirs_templates":[{"id":"t1","list":["DCIM"]}],"packages":['
  printf '%s' '{"package_name":"com.vi\nctim","enabled":true,"mount_dirs":{"template_ids":["t1"]}},'
  printf '%s' '{"package_name":"com.vi\"ctim","enabled":true,"mount_dirs":{"template_ids":["t1"]}},'
  printf '%s' '{"package_name":"com.ok","enabled":true,"mount_dirs":{"template_ids":["t1"]}}]}'
} > "$T/c11.json"
out11=$(run "$T/c11.json")
case "$out11" in
  *error=config*) bad "非法包名把整份配置判成损坏（应只丢该记录）：$out11" ;;
  *) ok "非法包名不影响整份配置" ;;
esac
case "$out11" in
  *ctim*) bad "非法 package_name 进入了输出：$out11" ;;
  *) ok "含换行/引号的 package_name 被丢弃" ;;
esac
# 直接看解析器输出：非法包名不能产生任何 Q/P/D 行，合法包名必须保留
SI_TEST=1 SI_TEST_NOW=1800000000 awk -f scripts/si-config.awk "$T/c11.json" 2>/dev/null > "$T/p11.txt"
if grep -q 'ctim' "$T/p11.txt"; then
  bad "解析器仍输出非法包名的行：$(grep 'ctim' "$T/p11.txt" | head -2)"
else
  ok "解析器对非法包名 fail-closed（无 Q/P/D 行）"
fi
if grep -q '^Q|com.ok$' "$T/p11.txt"; then ok "解析器保留合法包名"; else bad "解析器丢失合法包名"; fi

echo
[ "$fail" = 0 ] && { echo "config.test: PASS"; exit 0; }
echo "config.test: FAIL"; exit 1
