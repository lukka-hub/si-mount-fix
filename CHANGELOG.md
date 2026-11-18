# 更新日志

## 1.5.4

- 补丁目标改为 Zygisk 模块 `zygisk-storage-isolation` 的 `main.dex`：只替换
  `/data/adb/modules/zygisk-storage-isolation/main.dex`，重启手机后由 Zygisk 模块加载并保持。
  不再依赖 SI 的 server dex —— SI 的 `daemon-v355` 每次启动（含开机）都会把内嵌原版写回
  `server-v355.dex`，补它每次开机必被还原，没有持久意义。
- 补丁资产换成社区验证的 `assets/main.dex`（99,104 B / sha256
  `6d4058bc1c66fc14dec2331a603404a59c271d8a4b8f63c5270ff7029a8b80a7`）；原版 main.dex 为
  90,740 B / sha256 `a407674bba778267bac3d50bbdf528fa72fc219f46ef0463ad91bc58a56e82b9`。
  apply 前校验资产与目标哈希/大小，备份到 `patch-backup/main.dex.<时间戳>`（600），
  原子替换为 644 root:root，失败自动回滚。
- WebUI 去掉 `SERVER_PIDS`、`/proc` 全量扫描和 SI server 重启/等待：apply/restore 只做文件操作，
  结果直接返回，不再有 18 秒复核；成功提示“已应用，重启手机生效”。补丁卡片改为
  「Android 17 应用列表修复（main.dex）」，版本/哈希不匹配时置灰，unknown 仅提示/强制恢复。
- 卸载前恢复改为 `main.dex`；备份保留逻辑不变。文档同步适用条件（zygisk-storage-isolation
  v29.0.1 / main.dex）、备份/恢复、重启生效，以及官方更新覆盖后需重打。
- 版本 v1.5.4 / 154。
