#!/system/bin/sh
# RESULT 行契约（唯一实现）。
#
# 生产端 scripts/fix-si-mounts.sh 与 tools/*.test.sh 里的 fix stub 都 source 本文件，
# 避免 daemon 解析的 token（checked/broken/fixed/young/defer/error/skipped/churn/retry）
# 只在某一侧改动而测试仍绿。
#
# 用法：
#   . "${0%/*}/result.sh"
#   result_line <checked> <broken> <fixed> <young> [key=value ...]
#
# 输出（单行、末行，daemon 用 sed 逐字段解析，不依赖顺序）：
#   RESULT checked=N broken=N fixed=N young=N [key=value ...]
#
# 规则：
#   - 四个计数不是纯十进制数字时按 0，保证 daemon 的 sed 一定能取到数；
#   - 额外字段按传入顺序追加，key 必须是 [a-z][a-z0-9_]*，值只允许
#     [A-Za-z0-9_+.-]（真实取值示例：defer=fuse、error=config、
#     skipped=locked+identity、skipped=dir_space、defer=fuse）；
#   - 非法字段丢弃、该行其余部分照常输出，并返回 2（调用方/测试应视为契约错误）；
#   - 不打印其它内容、不写文件、不加锁。
# 契约由 tools/result.test.sh 验证。

_result_num() {
  case "${1:-}" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$1" ;;
  esac
}

result_line() {
  _rl_out="RESULT checked=$(_result_num "${1:-}")"
  _rl_out="$_rl_out broken=$(_result_num "${2:-}")"
  _rl_out="$_rl_out fixed=$(_result_num "${3:-}")"
  _rl_out="$_rl_out young=$(_result_num "${4:-}")"

  _rl_bad=0
  if [ "$#" -ge 4 ]; then
    shift 4
  elif [ "$#" -gt 0 ]; then
    # 少于 4 个计数：后面的参数无法与计数区分，丢弃并按契约错误返回 2，
    # 避免调用方少传一个计数时 defer=/error= 被静默丢弃、还当成成功。
    _rl_bad=2
    shift "$#"
  fi

  # 契约错误统一返回 2，方便测试区分“有输出但字段非法”。
  for _rl_kv in "$@"; do
    _rl_key=${_rl_kv%%=*}
    case "$_rl_kv" in
      *=*) ;;
      *) _rl_bad=2; continue ;;
    esac
    case "$_rl_key" in
      ''|[!a-z]*|*[!a-z0-9_]*) _rl_bad=2; continue ;;
    esac
    # checked/broken/fixed/young 是保留字段：重复出现会让 daemon 的贪婪 sed 取到伪值
    case "$_rl_key" in
      checked|broken|fixed|young) _rl_bad=2; continue ;;
    esac
    case "${_rl_kv#*=}" in
      '') _rl_bad=2; continue ;;
      *[!A-Za-z0-9_+.-]*) _rl_bad=2; continue ;;
    esac
    _rl_out="$_rl_out $_rl_kv"
  done

  printf '%s\n' "$_rl_out"
  return "$_rl_bad"
}
