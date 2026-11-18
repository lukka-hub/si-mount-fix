#!/system/bin/sh
# 沙箱日志格式与去重（真实 si-mount-eventd.sh + fix stub）
#
# 覆盖：
#   1) gone 日志带 pid/uid/ns/reason/isolated，统一标“下一轮重试”（gone 都写退避）；
#   2) na（isolated/无 storage）日志带同样字段并标“跳过”；
#   3) 报告每轮都变（模拟其它包事件）时，同一事件的 gone/na 仍只记一次（退避期不刷日志）；
#   4) 重建成功、或事件从报告里消失（SI 自愈）后，下一次真丢沙箱还能再记一条。
#
# 用法：sh tools/sandboxlog.test.sh
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1
DAEMON=scripts/si-mount-eventd.sh
# 解释器可移植：默认 Android 的 /system/bin/sh；缺 read -t 的 shell 跳过本测试。
DSH=${SI_TEST_SHELL:-${SI_TEST_SH:-/system/bin/sh}}
if ! { command -v "$DSH" >/dev/null 2>&1 && "$DSH" -c ':' >/dev/null 2>&1; }; then
  DSH=$(command -v mksh 2>/dev/null)
fi
if [ -z "$DSH" ] || ! { command -v "$DSH" >/dev/null 2>&1 && "$DSH" -c ':' >/dev/null 2>&1; }; then
  DSH=$(command -v sh 2>/dev/null)
fi
if [ -z "$DSH" ] || ! { command -v "$DSH" >/dev/null 2>&1 && "$DSH" -c ':' >/dev/null 2>&1; }; then
  echo "找不到 mksh/sh（可用 SI_TEST_SH=... 指定）"; exit 1
fi
"$DSH" -c 'read -t 1 _probe' </dev/null >/dev/null 2>&1
case $? in
  0|1) ;;
  *) echo "需要支持 read -t 的 shell（mksh），当前 $DSH 不支持"; exit 1 ;;
esac

T=${TMPDIR:-/tmp}/si-sandboxlog-test.$$
DATA=$T/data; MOD=$T/mod; TRACE=$T/trace
DPID=""
cleanup() {
  [ -n "$DPID" ] && kill -9 "$DPID" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT INT TERM HUP
mkdir -p "$DATA" "$MOD/scripts" "$MOD/webroot" "$TRACE" || exit 1
printf 'ENABLED=1\nMODE=auto\nPOLL_INTERVAL=10\nMIN_AGE=15\n' > "$DATA/config.conf"
printf 'version=v1.4.2\nversionCode=142\ndescription=x\n' > "$MOD/module.prop"
cp scripts/result.sh "$MOD/scripts/result.sh" || exit 1
cat > "$MOD/scripts/fix-si-mounts.sh" <<'S'
#!/bin/sh
. "$(dirname "$0")/result.sh"
case "$1" in --trim-only) exit 0 ;; esac
# 轮次计数：让每轮报告内容都变化，强制 daemon 重新处理报告；
# com.victim/com.retry/com.na 三行每轮相同，用来验证“按事件去重”。
_n=$(cat "$SI_DATA/.round" 2>/dev/null)
case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
_n=$((_n + 1))
echo "$_n" > "$SI_DATA/.round"
: > "$SI_DATA/.sandbox_report"
echo "gone com.victim pid=16514 uid=99035 ns=mnt:[4026536276] reason=owner isolated=1" >> "$SI_DATA/.sandbox_report"
echo "gone com.retry pid=9 uid=10123 ns=mnt:[4026536010] reason=bindfail isolated=0" >> "$SI_DATA/.sandbox_report"
echo "na com.na pid=55 uid=10421 ns=mnt:[4026536111] reason=no-storage isolated=0" >> "$SI_DATA/.sandbox_report"
if [ "$_n" = 1 ]; then
  echo "gone com.relost pid=7 uid=10555 ns=mnt:[4026536222] reason=missing isolated=0" >> "$SI_DATA/.sandbox_report"
elif [ "$_n" = 2 ]; then
  echo "rebuilt com.relost" >> "$SI_DATA/.sandbox_report"
else
  echo "gone com.relost pid=7 uid=10555 ns=mnt:[4026536222] reason=missing isolated=0" >> "$SI_DATA/.sandbox_report"
fi
# com.heal：第 1、3 轮丢失，第 2 轮从报告里消失（模拟 SI 自愈、没有 rebuilt）：
# 旧签名必须在事件消失的那一轮被清掉，第 3 轮重新记一条。
if [ "$_n" != 2 ]; then
  echo "gone com.heal pid=66 uid=10666 ns=mnt:[4026536333] reason=owner isolated=0" >> "$SI_DATA/.sandbox_report"
fi
# 每轮换一行其它事件：报告内容不相同，daemon 才会重新处理（否则整份报告被去重）。
if [ $((_n % 2)) = 1 ]; then
  echo "skip com.alpha" >> "$SI_DATA/.sandbox_report"
else
  echo "skip com.beta" >> "$SI_DATA/.sandbox_report"
fi
result_line 0 0 0 0
S
chmod 755 "$MOD/scripts/fix-si-mounts.sh" "$MOD/scripts/result.sh"

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }
wait_rounds() {   # $1=轮次；最多 45s（首轮立即跑，之后每 10s 一轮）
  _i=0
  while [ "$_i" -lt 450 ]; do
    _c=$(cat "$DATA/.round" 2>/dev/null)
    case "$_c" in ''|*[!0-9]*) _c=0 ;; esac
    [ "$_c" -ge "$1" ] && return 0
    sleep 0.1; _i=$((_i + 1))
  done
  return 1
}
count() { grep -c "$1" "$DATA/daemon.log" 2>/dev/null; }

# SI_TRACE 指向没有 kprobe_events 的目录 → 轮询模式，daemon 会正常跑 fix。
SI_DATA=$DATA SI_MOD=$MOD SI_TRACE=$TRACE "$DSH" "$DAEMON" >"$T/daemon.out" 2>&1 &
DPID=$!

if wait_rounds 3; then
  ok "daemon 跑了 3 轮 fix"
else
  bad "daemon 没有跑满 3 轮（$(cat "$DATA/.round" 2>/dev/null)）：$(tail -5 "$T/daemon.out" 2>/dev/null)"
fi
# 等最后一轮的日志落盘（报告处理在 status 写入前）。
sleep 1

n=$(count '沙箱丢失: com.victim')
[ "${n:-0}" = 1 ] && ok "同一事件 3 轮只记一次 com.victim gone（$n）" \
  || bad "com.victim gone 日志重复/缺失（$n 次）：$(grep '沙箱丢失' "$DATA/daemon.log" 2>/dev/null)"
grep -qF '沙箱丢失: com.victim (pid=16514 uid=99035 ns=mnt:4026536276 reason=owner isolated=1, 下一轮重试)' \
  "$DATA/daemon.log" 2>/dev/null \
  && ok "gone 日志格式：pid/uid/ns/reason/isolated + 标“下一轮重试”" \
  || bad "com.victim gone 格式不对：$(grep '沙箱丢失' "$DATA/daemon.log" 2>/dev/null)"

n=$(count '沙箱丢失: com.retry')
[ "${n:-0}" = 1 ] && ok "bindfail 事件 3 轮只记一次（$n）" \
  || bad "bindfail 日志重复/缺失（$n 次）：$(grep 'com.retry' "$DATA/daemon.log" 2>/dev/null)"
grep -qF '沙箱丢失: com.retry (pid=9 uid=10123 ns=mnt:4026536010 reason=bindfail isolated=0, 下一轮重试)' \
  "$DATA/daemon.log" 2>/dev/null \
  && ok "可重试原因（bindfail）标“下一轮重试”" \
  || bad "bindfail 日志格式不对：$(grep 'com.retry' "$DATA/daemon.log" 2>/dev/null)"

n=$(count '沙箱跳过: com.na')
[ "${n:-0}" = 1 ] && ok "na（isolated/无 storage）事件 3 轮只记一次（$n）" \
  || bad "na 日志重复/缺失（$n 次）：$(grep 'com.na' "$DATA/daemon.log" 2>/dev/null)"
grep -qF '沙箱跳过: com.na (pid=55 uid=10421 ns=mnt:4026536111 reason=no-storage isolated=0, 跳过)' \
  "$DATA/daemon.log" 2>/dev/null \
  && ok "na 日志带 pid/uid/ns/reason 并标“跳过”" \
  || bad "na 日志格式不对：$(grep 'com.na' "$DATA/daemon.log" 2>/dev/null)"

n=$(count '沙箱丢失: com.heal')
[ "${n:-0}" = 2 ] && ok "事件中途消失（SI 自愈、无 rebuilt）会清旧签名，再丢重新记（$n）" \
  || bad "事件消失后旧签名没有清掉（$n 次）：$(grep 'com.heal' "$DATA/daemon.log" 2>/dev/null)"
grep -qF '沙箱丢失: com.heal (pid=66 uid=10666 ns=mnt:4026536333 reason=owner isolated=0, 下一轮重试)' \
  "$DATA/daemon.log" 2>/dev/null \
  && ok "自愈后重新记的 gone 仍是同一格式" \
  || bad "com.heal 日志格式不对：$(grep 'com.heal' "$DATA/daemon.log" 2>/dev/null)"

n=$(count '沙箱重建: com.relost')
[ "${n:-0}" = 1 ] && ok "重建成功后记一条 rebuilt（$n）" \
  || bad "rebuilt 日志不对（$n 次）：$(grep 'com.relost' "$DATA/daemon.log" 2>/dev/null)"
n=$(count '沙箱丢失: com.relost')
[ "${n:-0}" = 2 ] && ok "重建后清掉旧签名：再次丢失会重新记一条（$n）" \
  || bad "重建后旧签名没有清掉/重复抑制（$n 次）：$(grep 'com.relost' "$DATA/daemon.log" 2>/dev/null)"
grep -q '沙箱丢失: com.relost (pid=7 uid=10555 ns=mnt:4026536222 reason=missing isolated=0, 下一轮重试)' \
  "$DATA/daemon.log" 2>/dev/null \
  && ok "relost 第二次丢失沿用同一事件格式" \
  || bad "relost 日志格式不对：$(grep 'com.relost' "$DATA/daemon.log" 2>/dev/null)"

# 状态字段不能被 na/报告带偏：daemon 只按 RESULT 的 skipped tag 置位。
case "$(cat "$DATA/status.json" 2>/dev/null)" in
  *'"sandbox_skip":0'*) ok "na 不置 status.sandbox_skip（UI 文案保持安全拒绝语义）" ;;
  *) bad "na 把 status.sandbox_skip 带成 1：$(cat "$DATA/status.json" 2>/dev/null)" ;;
esac

echo
[ "$fail" = 0 ] && { echo "sandboxlog.test: PASS"; exit 0; }
echo "sandboxlog.test: FAIL"; exit 1
