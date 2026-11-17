## 1.4.3 边界收口

- **按原 root 恢复回滚**：卸普通 FUSE 根前记下 `(设备号, root)`；恢复时 root=`/` 用
  `/storage/emulated`，root=`/0` 优先从 FUSE 层 `/0` 挂回、应用 namespace 看不到时退回
  self-bind；恢复后必须“一层、设备号等于原值、root 等于原值”才打印已挂回，否则报
  `rollback`/`stale`。其它 root 不卸也不恢复。
- **裁剪不误删在跑的临时文件**：`--trim-only` 只清 PID 已退出或超过 30 分钟的
  `.si-out.dry.*` / `.si-conf.*` / `.si-parsed.*` / `.conf.cache.tmp.*`，活 PID 的新文件保留。
- **锚点目录缺失上报**：主扫描与重建循环里 `-d` 失败不再静默跳过，报
  `skipped=target_missing`、计入 `broken`，日志写出缺失的路径。
- **本次修复跟随当前轮**：守护每轮成功扫描都把 `last_fixed` 更新为本轮 `fixed`（0 也归零），
  累计值仍放在 `total_fixed`。
- **退避与 glob**：`.repairs` 的退避改看 `/proc/uptime` 单调时间，系统时间跳变不影响；
  旧格式（只写墙钟）的失败行按无退避处理，`retry=` 仍是剩余秒数。重建沙箱遍历
  `rb_allow` 时关闭 glob 展开，自定义目录名里的 `*` 按字面量补挂。
- **PID/ns 时点校验**：扫描时记录 pid 的 starttime（`/proc/<pid>/stat` 第 22 字段）、uid 与
  mount namespace，bind/umount 前重读比对，不一致报 `skipped=pid_changed` 且不碰挂载；
  扫描与动手之间的极短窗口保留在文档里说明。
- **版本**：`v1.4.3` / `versionCode 143`。

##