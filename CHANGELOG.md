# 更新日志

## 1.6.0

- 内置两份 main.dex，按 Android SDK 自动选择：Android 17（SDK 37）用 `assets/main-a17.dex`，Android 15/16（SDK 35/36）用 `assets/main-a15.dex`；SDK 35 以下不提供补丁。仍只替换 `zygisk-storage-isolation` 的 `main.dex`，适用版本仍为 v29.0.1 / versionCode 89。
- 应用列表修复（A17）：保留 `a1` 的 4 条 `PackageInfoList` 调用，修复 Android 17 上 SI 应用列表为空。
- MediaStore 导出修复（A17）：`u0.invoke` 增加 `getService2` / `checkService2` 分支，恢复 ActivityManager wrapper，导出规则重新生效。
- A15/A16 资产：从原版 90,740 B / `a407674b…` 基线重建，`u0.invoke` 同时兼容 A15 QPR1 的 `IBinder` 返回和 A15 QPR2+/A16/A17 的 `android.os.Service` 返回；不直接引用 `android.os.Service` / `ServiceWithMetadata`，类加载安全。**未上机验证**，只做了 dex 头部 checksum/SHA-1 与 baksmali 反汇编结构校验，建议先在目标机型抓 logcat。
- 资产校验：A17 `main-a17.dex` 88,808 B / sha256 `3eafcb101fe7ae9eaa7e5614a55275391c37d3b012c4d4c814276b0215700fcc`（已真机验证）；A15 `main-a15.dex` 88,972 B / sha256 `2ecb548bdc3684532ec1ec6358cf8e6006968baf72517ecab22e360359a9833a`（未上机验证）。
- `si-patch.sh` 的 `check` 新增 `ASSET` / `VARIANT` 输出；`apply` 按 SDK 选资产；`restore` 可识别 A17/A15 两种补丁并恢复原版。版本/哈希门禁保持不变。
- 版本：`v1.6.0` / `versionCode 1600`。
