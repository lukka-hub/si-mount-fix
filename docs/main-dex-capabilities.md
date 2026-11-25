# v2.2 main.dex 能力说明

适用：Storage Isolation 8.8.1.r3684 / 增强模块 v29.0.1（versionCode 89），Android 15/16/17（SDK 35/36/37）。  
同一份 `main.dex`（99,840 B / `5e342a66…`），运行时按系统能力探测，不按 SDK 拆资产。

## 一句话

在 **MediaProvider / DownloadProvider 这一层**补上 SI 沙箱的读写检查：隔离应用可以继续访问自己的沙箱目录，但不能借 provider 读取、列出、删除、写入授权范围外的共享存储文件。

## 读：被拒绝的路径

| 读入口 | 行为 |
|---|---|
| `MediaStore.Files.external_primary` 查询 | 授权外返回 0 行；不再泄漏 DCIM 全量 |
| Images / Video / Audio / Downloads / Files 的 collection query | 授权外 0 行 |
| item URI 的 `_data` 查询 | 不返回授权外真实路径 |
| `openFile` / `openAssetFile` / `openTypedAssetFile` | 授权外抛 `SecurityException`，或打开后按 fd 复核关闭 |
| `openInputStream` / `openOutputStream` | 同上，由底层 open 路径拦截 |
| `openFileDescriptor` / `openAssetFileDescriptor` / `openTypedAssetFileDescriptor` | fd 路径不在允许范围时拒绝；错误信息 `SI provider guard: fd outside allowed scope` |

判定以 **fd 的实际路径**为准（`/proc/self/fd` readlink），不只看 URI 字符串；`external_primary`、UUID 卷、`/storage/self/primary`、`/mnt/user/0/emulated` 都会归一化后再比对。

## 写：被拒绝的路径

| 写入口 | 行为 |
|---|---|
| `MediaStore` insert（Images/Video/Audio/Downloads/Files） | 授权外返回 `null`，不落盘 |
| `bulkInsert` | 授权外返回 0 |
| `applyBatch` | 路径改写失败时整批拒绝，抛 `SecurityException` |
| `delete` | 授权外不删除；返回 0 或拒绝 |
| `update` 的 `_data` / `relative_path` / 放置位置 | 越界拒绝；只有 `_data` 的 update fail-closed |
| DownloadProvider insert/update | 规范化 hint、拒绝 `..`；越界不写 |
| `openFile` / `openAssetFile` 的 `wt` / `rwt` | 授权外、且路径不可判定时 **open 前拒绝**，避免先 truncate |
| 直接路径写 `/storage/emulated/0/DCIM`、`Download` | SI 沙箱内只写沙箱；真实 `/data/media/0` 不落盘 |

已知边界：`w` 模式（不带 `t`）在路径不可判定时仍可能先创建空文件，再由 fd 复核关闭；不会写入内容，但不是“零副作用”。`q0.b` 的 update placement 检查偏严，部分合法 rename/move 会被 `rows=0`；这是 fail-closed 取舍，不是漏放。

## 为存储空间提供的保留下来的能力

- **应用列表**：Android 17 `PackageInfoList → List` 适配，修复 SI 空列表；A15/16 继续兼容 `ParceledListSlice`。
- **MediaProvider 导出规则**：accessible 目录、observer 的 source→target 在 insert/update 生效；`relative_path` 越界拒绝/改写。
- **applyBatch**：Media/Download 批量 insert/update 逐 op 改写；back-reference 整批拒绝。
- **DownloadProvider**：`v.f` hint 规范化、拒绝 `..`、`/my_downloads` 前缀、批量 insert。
- **ServiceManager**：A15/16/17 的 `getService2` / `checkService2` / `ServiceWithMetadata` 形态适配。
- **自身目录与允许目录**：SI 沙箱目录、`Android/data|media|obb/<pkg>`、配置的 accessible 目录/observer 仍正常读写。
- **挂载自愈**：与 main.dex 独立；共享目录丢失时按事件修复，失败回滚，不改 SI 配置。
- **运行时开关**：系统属性 `persist.si_mount_fix.provider_guard`：
  - `1`（默认）：enforce；
  - `log`：只记录不拒绝；
  - `0`：关闭 guard。

## 明确不覆盖 / 未验证

- SAF 用户主动授权的整树访问、`createWriteRequest` / trash；
- DownloadManager 真实下载内容落盘（只验证了 enqueue 与 provider 写入口）；
- 多用户、32 位进程、无媒体权限的负向组合；
- Android 15/16 真机全量 E2E（A17 真机为主，A15/16 为静态/harness）；
- `w` 模式的空文件创建副作用（见上）；
- `q0.b` 的合法 update 过度拦截（fail-closed，已知）。

## 验证记录（A17 真机）

- 7 个 query 面：0 行；
- `openFD` / `openInputStream` / `openAssetFD` / `openTypedFD`：全部拒绝；
- `MediaStore` insert：`null`；`bulkInsert`：0；`applyBatch`：`path rewrite failed`；
- 授权外的直接路径写：沙箱内成功、真实 `/data/media/0` 无文件；
- 自身/允许目录：读写正常；
- 最小探针：`probe/DCIMGrid.apk`（读取 DCIM 与写 Hello World）。
