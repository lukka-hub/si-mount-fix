# 更新日志

## v2.0.0（versionCode 2000）

自包含通用 dex 兼容层：`assets/main.dex` 为 92,856 B / sha256
`2f3ca3263225d2577ab132e16dcc7273a61a80feea232b2f32e0100f6b3c8a22`，
Android 15/16/17 共用一份，不按版本换 dex。

### 新增能力

- **兼容性检测**：原「Android 17 应用列表修复（main.dex）」改为「兼容性检测」，覆盖
  Android 15–17（SDK 35/36/37）的应用列表、MediaProvider 导出、applyBatch 和
  DownloadProvider。
- **自包含通用 dex**：Apply 只替换
  `/data/adb/modules/zygisk-storage-isolation/main.dex`，重启生效；自动备份、校验、
  失败回滚。
- **运行时能力探测**：a1 按 `getInstalledPackages` 的实际返回对象适配；u0 只在系统真的
  调用到某个方法名时处理；u2 用反射尝试 `ServiceWithMetadata`/`Service.binder`；类/方法
  缺失时回原路径或空跑。
- **状态颜色**：未注入/旧版/`unknown`/`no-target`/`unsupported` 为黄色并解释原因；
  `patched` 为绿色（即使模块版本不匹配也表示 dex 已注入，动作置灰）；检查/读取/动作失败为红色。
- **版本与能力展示**：面板显示 Android 版本、SDK 和能力摘要（`CAPS`）；`check` 增加
  `SDK_NAME`/`CAPS`。

### 恢复功能

- **应用列表**：A17 `PackageInfoList` → `List`；a1 action 7 是 server fallback 实际走的
  链路，action 8 保留原语义、不在列表链。A15/A16 继续兼容旧 `ParceledListSlice`。
- **MediaProvider 导出规则**：规则先于 accessible 放行；改写 `relative_path`/`_data`/
  `_display_name`；insert、bulkInsert、update 都进规则。
- **applyBatch**：Media/Download 逐 op 复用单条规则，结果数组/下标/back-reference 对齐；
  无法安全改写时整批拒绝，不静默放行。
- **DownloadProvider**：`hint` 改写、路径 canonical、拒绝 `..`、target 幂等、
  `/my_downloads` 前缀匹配；批量 update/delete 原样。
- **ServiceManager**：覆盖 `getService`、`checkService`、`getService2`、`checkService2`；
  只对 `activity`/`vold` 且返回非 `IBinder` 时反射适配，同一 binder 返回原对象。

### 兼容性

- 一份 dex，A15/A16/A17 共用，不按 SDK 拆资产。
- A15 不启用不存在的 `getService2`；系统提供 QPR union 时按实际类型适配。
- A16 `checkService` 为 `IBinder`、`checkService2` 返回 `Service`；A17 同形。
- dex 内对 `PackageInfoList`、`android.os.Service`、`ServiceWithMetadata` 的直接引用为 0。
- `server-v355` 不进入单 dex 交付：daemon 每次启动写回原版、03 直接引用 A17-only 类型、
  没有归档真机证据；03 仅作为 A17 可选兜底，不写“已集成”。

### 升级与回滚

- 旧版 88,336 B /
  `5413a01b6c49f360f3851af60be8820fcb8a4595d0c15697fcebac88b6d73891` 显示为旧版注入；
  Apply 先备份为 `main.dex.legacy.<时间戳>`，再写通用 dex；原版备份保留。
- 原版备份为 `patch-backup/main.dex.<时间戳>`（600）；`restore` 只认 sha256 为
  `a407674b…`（90,740 B）的备份。
- apply/restore 失败回滚；`unknown` 且有有效原版备份时用 `restore --force`；版本不匹配时
  拒绝 apply/restore/force。
- 上游覆盖后重新 `check`；状态变成 `unknown` 不要用旧备份强恢复；卸载不自动恢复
  `main.dex`，保留 `patch-backup`。

### 测试与限制

- A15/A17 模拟器 `dex2oat` 0 个 verification error、115/115 类加载；harness 58/58；
  baksmali→assemble 往返 byte-identical；禁止直接引用扫描 0。
- 未验证：A16、A15 QPR1/QPR2、真机、真机冷启动；真实 `IPackageManager`/PMS、真实
  MediaProvider/DownloadProvider E2E、`applyBatch` 的真实 `onTransact`、`q0.b` 跨 uid
  update、Download E2E。
- 不写“全量验收通过”；文档只保留 Bug 根因、脚本解决方案和 2.0 能力，旧版本对照交给
  git/CHANGELOG。

## 1.5.8.1

- 修正 versionCode 低于 1.5.7.1（1571）导致 Magisk 不显示更新；功能与 1.5.8 相同。

- 修复微信 isolated 子进程导致的假沙箱丢失日志；真实丢失仍会重建。微信按需拉起的 `com.tencent.mm:xweb_sandboxed_process_0…` 等子进程 uid 在 90000–99999，本来就没有 `/storage`，不是 SI 的隔离对象：扫描直接跳过，不再对这类进程探测/写 180 秒退避/计 broken；漏到重建路径时按 na 跳过（也不写退避）。只有 isolated uid 或从未隔离过（无本 boot seen 证据）的进程才按 na；有 seen 证据的普通应用即使 namespace 里没有存储根，也仍按真实丢失处理，`owner`/`missing` 照旧写 180 秒退避并在下一轮重试。`-n` 体检与真跑使用同一套 na/重建判定。
- `.sandbox_seen` 的重建证据加入进程 uid 与 `/proc/<pid>/stat` 第 22 字段 `starttime`：同一个 namespace inode 被内核回收复用给别的进程时不再假命中；旧格式行按“无证据”处理，回落到“源存在 + 属主匹配”，真实丢失仍会被发现。
- 沙箱日志带 `pid`/`uid`/`ns`/`reason`：`gone` 都会写 180 秒退避，日志统一标“下一轮重试”；`na`（isolated/无 storage，不写退避）标“跳过”。同一事件在退避/重试期间只记一次，事件从本轮报告消失（应用自愈或进程退出）后清掉签名，下一次真丢会重新记。
- main.dex 仍为 88,336 B / sha256 `5413a01b6c49f360f3851af60be8820fcb8a4595d0c15697fcebac88b6d73891`（未改动）。
