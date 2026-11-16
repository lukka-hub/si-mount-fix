#!/system/bin/sh
# 身份校验自测：真实 fix-si-mounts.sh（非 dry-run）+ 伪造 /proc（SI_TEST=1）
# nsenter 用 PATH stub 记录调用，断言身份不符时 0 次 mount/nsenter。
# 用法：sh tools/identity.test.sh
#
# 覆盖：
#   1) cmdline=com.victim、沙箱根是 com.attacker → skipped=identity，且不做任何 mount
#   2) 沙箱根 shared-com.victim + cmdline com.victim → 通过（shared- 先剥前缀）
#   3) /media/0/... 形态的伪造沙箱根同样被拒绝
#   4) 沙箱根与包名一致 → 不误杀（checked=1，无 skipped=identity）
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1
FIX=scripts/fix-si-mounts.sh

T=${TMPDIR:-/tmp}/si-identity-test.$$
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/data" "$T/bin" "$T/proc/self" "$T/proc/123" || exit 1
P=$T/proc

# 假 /proc/self/mountinfo：足以让 fuse_dev() 取到本机 FUSE 设备号
cat > "$P/self/mountinfo" <<'M'
100 1 0:50 / / rw - ext4 /dev/root rw
101 100 0:50 / /mnt/user/0/emulated rw - fuse /dev/fuse rw
102 100 0:50 / /storage/emulated rw - fuse /dev/fuse rw
M

# 沙箱根 + 一条 DCIM 挂载；$1=沙箱根的包名，$2=media 前缀（缺省空）
write_mountinfo() {
  cat > "$P/123/mountinfo" <<M
200 1 0:50 /${2:-}0/Android/data/$1/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
201 200 0:50 /${2:-}0/DCIM /storage/emulated/0/DCIM rw - fuse /dev/fuse rw
M
}

cat > "$T/bin/ps" <<'S'
#!/bin/sh
cat <<'P'
  PID   UID     ELAPSED ARGS
  123     0    01:00 com.victim
P
S
cat > "$T/bin/nsenter" <<'S'
#!/bin/sh
echo "$@" >> "$SI_TEST_NSENTER_LOG"
exit 1
S
chmod 755 "$T/bin/ps" "$T/bin/nsenter"

cat > "$T/conf.json" <<'J'
{"mount_dirs_templates":[{"id":"t1","list":["DCIM"]}],"apps":[{"package_name":"com.victim","enabled":true,"mount_dirs":true,"template_ids":["t1"]}]}
J

run_fix() {   # $1=cmdline 包名；真实模式，nsenter 用 stub 拦截
  printf '%s\0-x\0' "$1" > "$P/123/cmdline"
  rm -f "$T/nsenter.log"
  PATH=$T/bin:$PATH SI_TEST=1 SI_PROC=$P SI_CONF=$T/conf.json SI_DATA=$T/data \
    SI_MIN_AGE=5 SI_TEST_NSENTER_LOG=$T/nsenter.log \
    sh "$FIX" -q 2>&1
}

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }

# 1) 身份伪造：cmdline=com.victim，沙箱根=com.attacker
write_mountinfo com.attacker
out=$(run_fix com.victim)
case "$out" in
  *skipped=identity*) ok "cmdline=com.victim + 沙箱根 com.attacker → skipped=identity" ;;
  *) bad "身份伪造没有被拒绝：$out" ;;
esac
case "$out" in
  *"修复:"*|*fixed=1*) bad "身份不符仍尝试修复：$out" ;;
  *) ok "身份不符没有产生修复动作" ;;
esac
if [ -s "$T/nsenter.log" ]; then
  bad "身份不符仍调用了 nsenter/mount：$(cat "$T/nsenter.log")"
else
  ok "身份不符时没有任何 mount 调用"
fi

# 2) shared- 别名：沙箱根=shared-com.victim，cmdline=com.victim → 通过
write_mountinfo shared-com.victim
out=$(run_fix com.victim)
case "$out" in
  *skipped=identity*) bad "shared- 沙箱根被误判成身份不符：$out" ;;
  *) ok "shared- 前缀先剥掉再比对（root=shared-com.victim）" ;;
esac

# 3) /media/0/Android/data/... 形态的伪造根也拒绝
write_mountinfo com.attacker media/
out=$(run_fix com.victim)
case "$out" in
  *skipped=identity*) ok "/media/0/... 形态的沙箱根同样拒绝（skipped=identity）" ;;
  *) bad "/media 形态的身份伪造没有被拒绝：$out" ;;
esac

# 4) 正常匹配：不误杀
write_mountinfo com.victim
out=$(run_fix com.victim)
case "$out" in
  *skipped=identity*) bad "身份一致的进程被误判：$out" ;;
  *checked=1*) ok "身份一致时正常进入检查（checked=1）" ;;
  *) bad "身份一致的进程没有被检查：$out" ;;
esac

echo
[ "$fail" = 0 ] && { echo "identity.test: PASS"; exit 0; }
echo "identity.test: FAIL"; exit 1
