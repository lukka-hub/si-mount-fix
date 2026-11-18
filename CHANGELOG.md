# 更新日志

## 1.5.7.1

- 修复已重启后仍显示“重启手机生效”黄条：apply/升级写 `patch-pending-reboot`（启动标识），`check` 输出 `PENDING_REBOOT`，重启后标识变化自动清除；黄色提示只在待重启时显示。main.dex 仍为 88,336 B / sha256 `5413a01b6c49f360f3851af60be8820fcb8a4595d0c15697fcebac88b6d73891`。
