# si-config.awk — 把 Storage Isolation 的 configuration.json 解析成行协议。
#
# 用法：awk -f si-config.awk /data/adb/storage-isolation/configuration.json
#
# 输出（每行一个字段，| 分隔）：
#   Q|pkg              所有 app 记录（apps/packages 数组）的 package_name（供进程匹配；含未启用项）
#   P|pkg|en          带 mount_dirs 的 app；en=1 表示启用（缺省启用，与旧实现一致，
#                      只有显式 "enabled":false 或非布尔值才判停用）
#   D|pkg|dir          该 app 允许的目录（模板 + 自定义目录，已去重）
#   X|pkg|tag|dir      被跳过的目录；tag=dir_space/dir_invalid
#   U|pkg|id           未知模板 id（配置里没有；不猜内置目录，fail-closed）
#   W|id|tag|dir       模板里被跳过的目录
#
# 退出码：0 正常；2 JSON 结构损坏/截断；3 没找到 apps/packages 数组（未知 schema）。解析器只认结构，不懂 SI 语义；
# 语义判断（是否启用、是否修 data/media/obb）留给调用方，保持 fail-closed。
#
# 设计要点：一次读入全文，按字符串/括号深度切分，而不是按行 split（旧实现
# 在真正的多行 JSON 上会静默漏记录）。目录名必须能用空格安全拼接，含空格/
# 制表符/竖线/反斜杠/绝对路径/`.` `..` 的目录会被跳过并输出 X，调用方据此
# 打 skipped 标签，而不是猜一个挂载目标。

BEGIN {
  NAPP = 0
  NTPL = 0
}

{ buf = buf $0 "\n" }


function ws(i,  c) {
  # 压缩 JSON（SI 的常见写法）里没有结构性空白：NW=1 时直接跳过逐字符读取。
  # toybox awk 的 substr() 代价与“剩余长度”成正比，逐字符扫描是这里的主要开销。
  if (NW) return i
  while (i <= L) {
    c = substr(buf, i, 1)
    if (c == " " || c == "\t" || c == "\n" || c == "\r") i++
    else break
  }
  return i
}

# 从 i（必须是 "）跳到闭合引号之后；返回 -1 表示截断。

# 处理 JSON 字符串转义；\uXXXX 只解 ASCII，其余保持字面量（包名/目录不会用到）。
function unescape(s,  r, i, c, n, h) {
  if (index(s, "\\") == 0) return s
  r = ""
  i = 1
  while (i <= length(s)) {
    c = substr(s, i, 1)
    if (c != "\\") { r = r c; i++; continue }
    if (i == length(s)) { r = r "\\"; break }
    c = substr(s, i + 1, 1)
    if (c == "n") r = r "\n"
    else if (c == "t") r = r "\t"
    else if (c == "r") r = r "\r"
    else if (c == "b") r = r "\b"
    else if (c == "f") r = r "\f"
    else if (c == "/") r = r "/"
    else if (c == "\\") r = r "\\"
    else if (c == "\"") r = r "\""
    else if (c == "u") {
      h = substr(s, i + 2, 4)
      n = 0
      if (h ~ /^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$/) {
        n = hexval(h)
        if (n >= 32 && n < 127) r = r sprintf("%c", n)
        else r = r "\\u" h
      } else r = r "u"
      i = i + 6
      continue
    }
    else r = r c
    i = i + 2
  }
  return r
}

function hexval(h,  i, c, n, v) {
  n = 0
  for (i = 1; i <= 4; i++) {
    c = tolower(substr(h, i, 1))
    v = index("0123456789abcdef", c) - 1
    if (v < 0) return 0
    n = n * 16 + v
  }
  return n
}

function pstr(i,  j, p, nb) {
  if (substr(buf, i, 1) != "\"") return -1
  j = i + 1
  while (j <= L) {
    # 一次跳到下一个引号（C 级搜索）；只有前面是反斜杠时才需要继续找。
    p = index(substr(buf, j), "\"")
    if (p == 0) return -1
    j = j + p - 1
    nb = 0
    while (j - 1 - nb >= i && substr(buf, j - 1 - nb, 1) == "\\") nb++
    if (nb % 2 == 0) return j + 1
    j++
  }
  return -1
}

# 跳过任意 JSON 值；返回结束位置（不含），-1 表示结构损坏。
function pval(i,  c, j, depth) {
  i = ws(i)
  if (i > length(buf)) return -1
  c = substr(buf, i, 1)
  if (c == "\"") return pstr(i)
  if (c == "{" || c == "[") {
    depth = 0
    while (i <= L) {
      c = substr(buf, i, 1)
      if (c == "\"") {
        j = pstr(i)
        if (j < 0) return -1
        i = j
        continue
      }
      if (c == "{" || c == "[") depth++
      else if (c == "}" || c == "]") {
        depth--
        if (depth == 0) return i + 1
      }
      i++
    }
    return -1
  }
  while (i <= L) {
    c = substr(buf, i, 1)
    if (c == "," || c == "}" || c == "]" || c == " " || c == "\t" || c == "\n" || c == "\r") break
    i++
  }
  return i
}

# 解析字符串数组，结果放 SA[1..SAN]；返回数组后的位置，-1 表示损坏。
function parse_strarray(start,  i, c, ve, s) {
  SAN = 0
  split("", SA)
  i = start + 1
  while (i <= L) {
    i = ws(i)
    c = substr(buf, i, 1)
    if (c == "]") return i + 1
    if (c == ",") { i++; continue }
    if (c != "\"") return -1
    ve = pstr(i)
    if (ve < 0) return -1
    s = unescape(substr(buf, i + 1, ve - i - 2))
    SA[++SAN] = s
    i = ve
  }
  return -1
}

function parse_templates(start,  i, c, ke, key, ve, t_id, t_dirs, tag, k, s, d) {
  i = start + 1
  while (i <= L) {
    i = ws(i)
    c = substr(buf, i, 1)
    if (c == "]") return i + 1
    if (c == ",") { i++; continue }
    if (c != "{") return -1
    t_id = ""
    t_dirs = ""
    i++
    while (i <= L) {
      i = ws(i)
      c = substr(buf, i, 1)
      if (c == "}") { i++; break }
      if (c == ",") { i++; continue }
      if (c != "\"") return -1
      ke = pstr(i)
      if (ke < 0) return -1
      key = unescape(substr(buf, i + 1, ke - i - 2))
      i = ws(ke)
      if (substr(buf, i, 1) != ":") return -1
      i = ws(i + 1)
      if (key == "id") {
        ve = pstr(i)
        if (ve < 0) return -1
        t_id = unescape(substr(buf, i + 1, ve - i - 2))
        i = ve
      } else if (key == "list") {
        i = parse_strarray(i)
        if (i < 0) return -1
        for (k = 1; k <= SAN; k++) {
          d = trimdir(SA[k])
          tag = dir_tag(d)
          if (tag != "") { print "W|" t_id "|" tag "|" d; continue }
          t_dirs = t_dirs (t_dirs == "" ? "" : " ") d
        }
      } else {
        i = pval(i)
        if (i < 0) return -1
      }
    }
    if (t_id != "") {
      # 重复 id：后者覆盖前者，与旧实现一致（不额外报错）
      TD[t_id] = t_dirs
      TPL_ID[++NTPL] = t_id
    }
  }
  return -1
}


# mount_dirs 是对象：{flags, template_ids, custom_dirs}。旧实现靠正则扫整条记录，
# 新解析器必须下钻，否则模板目录全部丢失。
function parse_mount_dirs(start,  i, c, ke, key, ve, k) {
  i = ws(start)
  if (substr(buf, i, 1) != "{") return pval(i)
  i++
  while (i <= L) {
    i = ws(i)
    c = substr(buf, i, 1)
    if (c == "}") return i + 1
    if (c == ",") { i++; continue }
    if (c != "\"") return -1
    ke = pstr(i)
    if (ke < 0) return -1
    key = unescape(substr(buf, i + 1, ke - i - 2))
    i = ws(ke)
    if (substr(buf, i, 1) != ":") return -1
    i = ws(i + 1)
    if (key == "template_ids") {
      i = parse_strarray(i)
      if (i < 0) return -1
      for (k = 1; k <= SAN; k++) MD_T = MD_T (MD_T == "" ? "" : SUBSEP) SA[k]
    } else if (key == "custom_dirs") {
      i = parse_strarray(i)
      if (i < 0) return -1
      for (k = 1; k <= SAN; k++) MD_C = MD_C (MD_C == "" ? "" : SUBSEP) SA[k]
    } else {
      i = pval(i)
      if (i < 0) return -1
    }
  }
  return -1
}

function parse_apps(start,  i, c, ke, key, ve, pkg, en, dseen, tids, cdirs, k) {
  i = start + 1
  while (i <= L) {
    i = ws(i)
    c = substr(buf, i, 1)
    if (c == "]") return i + 1
    if (c == ",") { i++; continue }
    if (c != "{") return -1
    pkg = ""
    en = 1
    dseen = 0
    tids = ""
    cdirs = ""
    MD_T = ""
    MD_C = ""
    i++
    while (i <= L) {
      i = ws(i)
      c = substr(buf, i, 1)
      if (c == "}") { i++; break }
      if (c == ",") { i++; continue }
      if (c != "\"") return -1
      ke = pstr(i)
      if (ke < 0) return -1
      key = unescape(substr(buf, i + 1, ke - i - 2))
      i = ws(ke)
      if (substr(buf, i, 1) != ":") return -1
      i = ws(i + 1)
      if (key == "package_name") {
        ve = pstr(i)
        if (ve < 0) return -1
        pkg = unescape(substr(buf, i + 1, ve - i - 2))
        i = ve
      } else if (key == "enabled") {
        ve = pval(i)
        if (ve < 0) return -1
        if (substr(buf, i, ve - i) == "true") en = 1
        else en = 0
        i = ve
      } else if (key == "mount_dirs") {
        dseen = 1
        i = parse_mount_dirs(i)
        if (i < 0) return -1
        if (MD_T != "") tids = tids (tids == "" ? "" : SUBSEP) MD_T
        if (MD_C != "") cdirs = cdirs (cdirs == "" ? "" : SUBSEP) MD_C
      } else if (key == "template_ids") {
        i = parse_strarray(i)
        if (i < 0) return -1
        for (k = 1; k <= SAN; k++) tids = tids (tids == "" ? "" : SUBSEP) SA[k]
      } else if (key == "custom_dirs") {
        i = parse_strarray(i)
        if (i < 0) return -1
        for (k = 1; k <= SAN; k++) cdirs = cdirs (cdirs == "" ? "" : SUBSEP) SA[k]
      } else {
        i = pval(i)
        if (i < 0) return -1
      }
    }
    if (pkg != "") {
      NAPP++
      APKG[NAPP] = pkg
      AEN[NAPP] = en
      AD[NAPP] = dseen
      ATIDS[NAPP] = tids
      ACUS[NAPP] = cdirs
    }
  }
  return -1
}

function trimdir(d,  n) {
  sub(/^[ \t\r\n]+/, "", d)
  sub(/[ \t\r\n]+$/, "", d)
  n = length(d)
  while (n > 1 && substr(d, n, 1) == "/") { d = substr(d, 1, n - 1); n-- }
  return d
}

# 返回 ""（可用）或 dir_space / dir_invalid；调用方据此跳过目录而不是猜目标。
function dir_tag(d,  n, p, i) {
  if (d == "") return "dir_invalid"
  if (index(d, " ") || index(d, "\t") || index(d, "\n") || index(d, "\r")) return "dir_space"
  if (index(d, "|")) return "dir_invalid"
  if (index(d, "\\") || index(d, "\"")) return "dir_invalid"
  if (substr(d, 1, 1) == "/") return "dir_invalid"
  n = split(d, p, "/")
  for (i = 1; i <= n; i++) {
    if (p[i] == "" || p[i] == "." || p[i] == "..") return "dir_invalid"
  }
  return ""
}

# 包名只允许 [A-Za-z0-9_.-]（shared- 前缀用到 -）：含换行/引号/竖线等会破坏
# Q/P/D 行协议或 list-apps 的 JSON，直接 fail-closed 丢弃该记录，不猜。
function valid_pkg(p,  i, c) {
  if (p == "" || length(p) > 255) return 0
  for (i = 1; i <= length(p); i++) {
    c = substr(p, i, 1)
    if (index("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-", c) == 0) return 0
  }
  return 1
}

function add_dir(pkg, d,  tag, key, n, arr, i, k, j) {
  d = trimdir(d)
  tag = dir_tag(d)
  if (tag != "") { print "X|" pkg "|" tag "|" d; return 0 }
  key = pkg SUBSEP d
  if (key in SEEN) return 0
  SEEN[key] = 1
  print "D|" pkg "|" d
}

function emit(  a, pkg, i, j, n, id, dirs, arr, cds, nd) {
  for (a = 1; a <= NAPP; a++) {
    pkg = APKG[a]
    if (!valid_pkg(pkg)) continue
    print "Q|" pkg
    if (!AD[a]) continue
    print "P|" pkg "|" AEN[a]
    if (AEN[a] != 1) continue
    n = split(ATIDS[a], arr, SUBSEP)
    for (i = 1; i <= n; i++) {
      id = arr[i]
      if (id == "") continue
      if (id in TD) dirs = TD[id]
      else { print "U|" pkg "|" id; continue }
      nd = split(dirs, cds, " ")
      for (j = 1; j <= nd; j++) add_dir(pkg, cds[j])
    }
    n = split(ACUS[a], cds, SUBSEP)
    for (i = 1; i <= n; i++) if (cds[i] != "") add_dir(pkg, cds[i])
  }
}

END {
  L = length(buf)
  if (buf == "") exit 2
  # 有没有“字符串之外”的空白：没有就跳过 ws() 的逐字符路径。
  _t = buf
  gsub(/[ \t\r\n]+$/, "", _t)
  NW = (index(_t, " ") + index(_t, "\t") + index(_t, "\n") + index(_t, "\r")) == 0
  i = ws(1)
  if (substr(buf, i, 1) != "{") exit 2
  i++
  while (1) {
    i = ws(i)
    if (i > length(buf)) exit 2
    c = substr(buf, i, 1)
    if (c == "}") { i++; break }
    if (c == ",") { i++; continue }
    if (c != "\"") exit 2
    ke = pstr(i)
    if (ke < 0) exit 2
    key = unescape(substr(buf, i + 1, ke - i - 2))
    i = ws(ke)
    if (substr(buf, i, 1) != ":") exit 2
    i = ws(i + 1)
    if (key == "mount_dirs_templates") {
      if (substr(buf, i, 1) != "[") exit 2
      i = parse_templates(i)
      if (i < 0) exit 2
    } else if (key == "apps" || key == "packages") {
      if (substr(buf, i, 1) != "[") exit 2
      have_apps = 1
      i = parse_apps(i)
      if (i < 0) exit 2
    } else {
      i = pval(i)
      if (i < 0) exit 2
    }
  }
  i = ws(i)
  if (i <= L) {
    # 根对象之后的空白可以接受（压缩 JSON 常带一个尾随换行）；NW=1 时 ws 不读字符。
    if (substr(buf, i) ~ /^[ \t\r\n]*$/) i = L + 1
  }
  if (i <= L) exit 2
  if (!have_apps) exit 3
  emit()
  exit 0
}
