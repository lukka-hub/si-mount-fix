#!/system/bin/sh
# v1.3.6 FUSE 未就绪语义：立即 defer，不阻塞等待
# 用法：sh tools/fusewait.test.sh
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1
FIX=scripts/fix-si-mounts.sh
# 解释器可移植：默认 Android 的 /system/bin/sh；不存在或不可执行（曾被替换成
# 设备节点）时回退 mksh → sh。用 `-c :` 真跑一次，比只 command -v 可靠。
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

T=${TMPDIR:-/tmp}/si-fusewait-test.$$
trap 'rm -rf "$T"' EXIT INT TERM HUP
mkdir -p "$T/data" "$T/bin" "$T/proc/self" "$T/proc/123" || exit 1
P=$T/proc

cat > "$T/conf.json" <<'J'
{"mount_dirs_templates":[{"id":"t1","list":["DCIM"]}],"apps":[{"package_name":"com.victim","enabled":true,"mount_dirs":true,"template_ids":["t1"]}]}
J
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

# FUSE 已就绪时用于扫描的候选进程（root 与包名一致，不应产生 mount）
cat > "$P/123/mountinfo" <<'M'
200 1 0:50 /0/Android/data/com.victim/sdcard /storage/emulated/0 rw - fuse /dev/fuse rw
M

run_fix() {
  rm -f "$T/nsenter.log"
  PATH=$T/bin:$PATH SI_TEST=1 SI_PROC=$P SI_CONF=$T/conf.json SI_DATA=$T/data \
    SI_MIN_AGE=5 SI_TEST_NSENTER_LOG=$T/nsenter.log \
    "$TEST_SH" "$FIX" -n -v 2>&1
}

# 毫秒时钟：GNU date 有 %3N，toybox/其它实现没有时退回秒级。
now_ms() {
  _ms=$(date +%s%3N 2>/dev/null)
  case "$_ms" in
    ''|*[!0-9]*) _ms="$(date +%s)000" ;;
  esac
  printf '%s\n' "$_ms"
}

# wall-clock 上限可用 SI_TEST_FUSEWAIT_MAX_MS 调整（慢机器/CI 放宽，默认 2000ms）。
# 只验证“立即返回、不阻塞等待”，不断言具体毫秒数。
FUSE_DEFER_MAX_MS=${SI_TEST_FUSEWAIT_MAX_MS:-2000}
case "$FUSE_DEFER_MAX_MS" in ''|*[!0-9]*) FUSE_DEFER_MAX_MS=2000 ;; esac

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }

# ---------- 1) FUSE 未就绪：必须立即 defer，不等待、不 mount ----------
cat > "$P/self/mountinfo" <<'M'
100 1 0:50 / / rw - ext4 /dev/root rw
M
t0=$(now_ms)
out=$(run_fix); rc=$?
t1=$(now_ms)
el=$((t1 - t0))
[ "$rc" = 0 ] && ok "defer 退出码 0（不是错误）" || bad "退出码不是 0：rc=$rc out=$out"
case "$out" in
  *defer=fuse*) ok "输出 defer=fuse" ;;
  *) bad "没有 defer=fuse：$out" ;;
esac
case "$out" in
  *error=*|*layer_unknown*) bad "defer 仍报错误：$out" ;;
  *) ok "defer 不写 error/layer_unknown" ;;
esac
case "$out" in
  *fixed=[1-9]*|*"修复:"*) bad "FUSE 未就绪仍尝试修复：$out" ;;
  *) ok "FUSE 未就绪时一条挂载都不动" ;;
esac
if [ -s "$T/nsenter.log" ]; then
  bad "FUSE 未就绪仍调用了 nsenter/mount：$(cat "$T/nsenter.log")"
else
  ok "FUSE 未就绪时没有 mount 调用"
fi
if [ "$el" -le "$FUSE_DEFER_MAX_MS" ]; then
  ok "立即返回，不阻塞（实测 ${el}ms <= ${FUSE_DEFER_MAX_MS}ms）"
else
  bad "仍在阻塞等待（实测 ${el}ms > ${FUSE_DEFER_MAX_MS}ms）"
fi

# ---------- 2) FUSE 已就绪：正常进入扫描 ----------
rm -f "$T/nsenter.log"
cat > "$P/self/mountinfo" <<'M'
100 1 0:50 / / rw - ext4 /dev/root rw
101 100 0:50 / /mnt/user/0/emulated rw - fuse /dev/fuse rw
102 100 0:50 / /storage/emulated rw - fuse /dev/fuse rw
M
t0=$(now_ms)
out=$(run_fix); rc=$?
t1=$(now_ms)
el=$((t1 - t0))
[ "$rc" = 0 ] && ok "FUSE 已就绪时正常结束（rc=0）" || bad "FUSE 已就绪时仍失败：rc=$rc out=$out"
case "$out" in
  *defer=fuse*|*error=*|*layer_unknown*) bad "FUSE 已就绪仍 defer/报错：$out" ;;
  *) ok "FUSE 已就绪时不 defer、不报错" ;;
esac
# 这个 fixture 没有源目录：1.4.3 起锚点缺失会报 target_missing 并计入 broken，
# 所以这里只断言“确实扫到了进程、没有动挂载”。
case "$out" in
  *checked=1*fixed=0*) ok "进入正常扫描（checked=1）" ;;
  *) bad "没有进入正常扫描：$out" ;;
esac

echo
[ "$fail" = 0 ] && { echo "fusewait.test: PASS"; exit 0; }
echo "fusewait.test: FAIL"; exit 1
