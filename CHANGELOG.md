# 更新日志

## 1.5.6

- **兼容社区旧补丁**：`check` 识别社区版 main.dex（99,104 B / sha256
  `6d4058bc1c66fc14dec2331a603404a59c271d8a4b8f63c5270ff7029a8b80a7`）为
  `patched-legacy`，并输出 `LEGACY=1`；不再显示 unknown/不支持。
- **从社区旧版升级**：`apply` 允许从 `patched-legacy` 升级到自建版：先把当前社区 dex 备份为
  `patch-backup/main.dex.legacy.<时间戳>`（600），原版备份（a407）保留用于恢复，再安装
  88,336 B / sha256 `5413a01b6c49f360f3851af60be8820fcb8a4595d0c15697fcebac88b6d73891`
  自建版；成功后 `STATE=patched` / `LEGACY=0`。
- **从社区旧版恢复**：`restore` 允许直接恢复原版，只认有效原版备份；没有原版备份时拒绝并提示
  “缺少原版备份，可先升级到自建版”；成功后 `STATE=original` / `LEGACY=0`。
- **WebUI**：`patched-legacy` 显示“旧版补丁”，提供“升级到自建版 / 恢复原版”和二次确认；
  unknown 改为“未知版本”，版本不匹配改为“版本不匹配”，不再用“不支持”混用。
- **按钮归一化**：动作按钮统一 44px 高、min-width、padding、字号、圆角和 margin；
  应用/升级为主按钮，恢复为次按钮，强制恢复仅红色边框/文字、不放大；「检查补丁」与耗时文字
  同一行，badge 与标题同一行右对齐，窄屏可换行。
- `check` 新增 `LEGACY` 字段（共 21 个 KEY=VALUE）；README 同步社区旧版升级/恢复与备份路径。
- 版本 v1.5.6 / 156。
