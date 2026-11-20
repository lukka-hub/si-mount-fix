# 更新日志

## v2.0.1（versionCode 2010）

- 模块名称和介绍调整为“兼容与挂载”：兼容性检测与挂载自愈并列为两项核心能力，没有先后顺序。
- 不改变 dex、脚本行为；仅调整展示与文档，已有用户可收到更新。

## v2.0（versionCode 2000）

兼容性检测使用一份 `main.dex`（92,856 B / sha256
`2f3ca3263225d2577ab132e16dcc7273a61a80feea232b2f32e0100f6b3c8a22`）通配
Android 15/16/17，运行时按系统能力探测，不按 SDK 拆资产；用户确认后替换
`zygisk-storage-isolation/main.dex`，重启手机生效。

### 版本号

- `v2.0` 按 `major*1000 + minor*100` 编码为 `versionCode=2000`，高于此前已发布版本的编码，
  Magisk 能识别为更新。
- 不采用 `1.60`/`160`：把两段版本压成三位编码会低于已发布版本，Magisk 会判定为回退，
  模块页不会显示更新。
- `module.prop`、`update.json`、README/CHANGELOG、`tools/build.sh` 与 CI 的 tag 规则
  统一为 `v2.0` / `2000`；发布 tag 使用 `v2.0`。

### 新增能力

- **兼容性检测**：覆盖 Android 15–17（SDK 35/36/37）的应用列表、MediaProvider 导出、
  applyBatch、DownloadProvider 和 ServiceManager。
- **单份 main.dex**：只替换 `zygisk-storage-isolation/main.dex`，重启生效；自动备份、
  校验、失败回滚，不重启 SI server、不改 `configuration.json`。
- **运行时能力探测**：a1/a2 按 `getInstalledPackages` 的实际返回对象适配；u0 只在
  系统真的调用到某个方法名时处理；u2 用反射尝试 `ServiceWithMetadata`/`Service.binder`；
  类/方法缺失时回原路径或空跑。
- **具体能力清单**：WebUI「兼容性检测（main.dex）」卡片新增 `#patchCaps` 区块，
  按 SDK 35/36/37 分别列出 6 条可恢复能力；`CAPS` 继续作为 `check` 的一行摘要。
- **状态颜色**：未注入/旧补丁格式/`unknown`/`no-target`/`unsupported` 为黄色并解释原因；
  `patched` 为绿色（即使模块版本不匹配也表示 dex 已注入，动作置灰）；检查/读取/动作
  失败为红色。

### 恢复功能

- **应用列表**：Android 17 的 `PackageInfoList` 经 a1/a2 转为 `List`，修复 SI 空列表；
  Android 15/16 继续兼容旧 `ParceledListSlice`，列表读取不受影响。
- **MediaProvider 导出规则**：accessible 目录和 observer 的 source→target 规则在
  insert/update 中生效；`relative_path` 越界拒绝或改写；只有 `_data` 的 update
  fail-closed。
- **applyBatch（仅 MediaProvider/DownloadProvider）**：批量 insert/update 逐 op 改写，已导出的文件不会再被批量 update
  移回源目录；带 back-reference 的整批拒绝，不静默放行。
- **DownloadProvider**：`v.f` 规范化 hint、拒绝 `..`、target 幂等；`v.d` 对
  `/my_downloads` 和 `/my_downloads/<id>` 前缀匹配；批量 insert 逐 op 走同一规则。
- **ServiceManager**：Android 15 release 不启用不存在的 `getService2`，QPR1/QPR2 按
  实际 `Service` union 适配；Android 16 按 `ServiceWithMetadata`/`checkService2`
  形态适配；Android 17 `getService2`/`checkService2` 返回 `Service`、`checkService`
  为 `IBinder`；只 hook `activity`/`vold`，同 binder 返回原对象。

### 升级与回滚

- 检测到 88,336 B /
  `5413a01b6c49f360f3851af60be8820fcb8a4595d0c15697fcebac88b6d73891` 的补丁 dex
  时显示为 `patched-legacy`；Apply 先把它备份为 `main.dex.legacy.<时间戳>`，再写通用
  dex，原版备份保留。
- 原版备份为 `patch-backup/main.dex.<时间戳>`（600）；`restore` 只认 sha256 为
  `a407674b…`（90,740 B）的备份。
- apply/restore 失败回滚；`unknown` 且有有效原版备份时用 `restore --force`；模块
  版本不匹配时拒绝 apply/restore/force。
- 上游覆盖后重新 `check`；状态变成 `unknown` 时不要用旧的原版备份强恢复；卸载不自动
  恢复 `main.dex`，保留 `patch-backup`。

### 测试与限制

- A15/A17 模拟器 `dex2oat` 0 个 verification error、115/115 类加载；harness 58/58；
  baksmali→assemble 往返 byte-identical；禁止直接引用扫描 0。
- 未验证：A16、A15 QPR1/QPR2、真机、真机冷启动；真实 `IPackageManager`/PMS、真实
  MediaProvider/DownloadProvider E2E、`applyBatch` 的真实 `onTransact`、`q0.b` 跨 uid
  update、Download E2E。
- 不包含 `server-v355.dex`：SI daemon 每次启动（含开机）会把内嵌原版写回 server dex，
  替换不持久；A17-only 的 03 直接引用 `PackageInfoList`，不是 A15–A17 通用资产，也没有
  归档真机证据。
