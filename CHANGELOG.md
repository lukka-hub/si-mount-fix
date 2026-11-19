# 更新日志

## 1.6.0

- A17 应用列表修复：保留 `a1` 的 4 条 `PackageInfoList` 调用，修复 Android 17 上 SI 应用列表为空。
- A17 MediaStore 导出修复：`u0.invoke` 增加 `getService2` / `checkService2` 分支，恢复 ActivityManager wrapper，导出规则重新生效。
- 只发 Android 17（SDK 37）：内置 `assets/main-a17.dex`；Android 15/16（SDK 35/36）与 SDK <35 不支持，A15/A16 待 1.6.1。
- 资产校验：`main-a17.dex` 88,808 B / sha256 `3eafcb101fe7ae9eaa7e5614a55275391c37d3b012c4d4c814276b0215700fcc`（已真机验证，测试后未改）。
- `si-patch.sh` 的 `check` 只报 A17 的 `ASSET` / `VARIANT`；`apply` 只认 SDK 37；`restore` 识别 A17 补丁和原版。
- 从 1.5.8.1 升级：旧自建补丁 88,336 B / `5413a01b…` 显示 `unknown`；先 `restore --force` 恢复原版（需版本匹配且存在原版备份），再 `apply` 安装 A17 资产。
- 版本：`v1.6.0` / `versionCode 1600`。
