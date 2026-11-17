#!/system/bin/sh
# 真实守护的“本次修复”归零：
#   fixed=2 的一轮 → status.json last_fixed=2、total_fixed=2；
#   下一轮 fixed=0   → last_fixed 归零，total_fixed 仍为 2。
#
# 用法：sh tools/lastfixed.test.sh
case "$0" in */*) D=${0%/*};; *) D=.;; esac
cd "$D/.." 2>/dev/null || exit 1
DAEMON=scripts/si-mount-eventd.sh
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

T=${TMPDIR:-/tmp}/si-lastfixed-test.$$
DATA=$T/data; MOD=$T/mod
DPID=""
cleanup() {
  [ -n "$DPID" ] && kill -9 "$DPID" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT INT TERM HUP
mkdir -p "$DATA" "$MOD/scripts" "$MOD/webroot" || exit 1
printf 'ENABLED=1\nMODE=poll\nPOLL_INTERVAL=10\nMIN_AGE=15\n' > "$DATA/config.conf"
printf 'version=v1.4.3\nversionCode=143\ndescription=x\n' > "$MOD/module.prop"
cp scripts/result.sh "$MOD/scripts/result.sh" || exit 1
cat > "$MOD/scripts/fix-si-mounts.sh" <<'S'
#!/bin/sh
. "$(dirname "$0")/result.sh"
case "$1" in --trim-only) exit 0 ;; esac
n=0
[ -r "$SI_DATA/.round" ] && read -r n < "$SI_DATA/.round"
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1))
printf '%s\n' "$n" > "$SI_DATA/.round"
if [ "$n" = 1 ]; then
  result_line 1 0 2 0
else
  result_line 1 0 0 0
fi
S
chmod 755 "$MOD/scripts/fix-si-mounts.sh" "$MOD/scripts/result.sh"

fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }
wait_status() {   # $1=要匹配的片段 $2=最多等几秒
  _i=0; _max=$(( $2 * 10 ))
  while [ "$_i" -lt "$_max" ]; do
    grep -q "$1" "$DATA/status.json" 2>/dev/null && return 0
    sleep 0.1; _i=$((_i + 1))
  done
  return 1
}

SI_DATA=$DATA SI_MOD=$MOD "$DSH" "$DAEMON" >"$T/daemon.out" 2>&1 &
DPID=$!

if wait_status '"last_fixed":2' 15; then
  ok "第一轮 fixed=2 写进 last_fixed"
else
  bad "last_fixed 没有变成 2：$(cat "$DATA/status.json" 2>/dev/null)"
fi
st=$(cat "$DATA/status.json" 2>/dev/null)
case "$st" in
  *'"total_fixed":2'*) ok "第一轮累计 total_fixed=2" ;;
  *) bad "total_fixed 不是 2：$st" ;;
esac

if wait_status '"last_fixed":0' 20; then
  ok "第二轮 fixed=0 后 last_fixed 归零"
else
  bad "last_fixed 没有归零（仍是上一轮的值）：$(cat "$DATA/status.json" 2>/dev/null)"
fi
st=$(cat "$DATA/status.json" 2>/dev/null)
case "$st" in
  *'"total_fixed":2'*) ok "归零不减少累计 total_fixed（仍 2）" ;;
  *) bad "归零把 total_fixed 改了：$st" ;;
esac
n=$(cat "$DATA/.round" 2>/dev/null)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
[ "$n" -ge 2 ] && ok "守护至少跑了两轮 fix（$n）" || bad "只跑了 $n 轮 fix"

echo
[ "$fail" = 0 ] && { echo "lastfixed.test: PASS"; exit 0; }
echo "lastfixed.test: FAIL"; exit 1
