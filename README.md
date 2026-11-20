# Storage Isolation 兼容与挂载

为 **Storage Isolation / 存储空间隔离**（`moe.shizuku.redirectstorage`）提供两项能力：

- **兼容性检测**：一份 `main.dex` 通配 Android 15/16/17（向下兼容）；运行时按系统能力探测，不按 SDK 拆资产。用户确认后替换 `zygisk-storage-isolation/main.dex`，重启手机后生效。
- **挂载自愈**：补回 SI 增强模式丢失的共享目录挂载；事件驱动、轮询兜底、失败回滚。

支持 Android 13~17，**Magisk / KernelSU**；不修改 SI 的
`configuration.json`，不联网，不收集数据。

## 问题与根因

SI 的增强模式会为每个被隔离应用准备各自的 mount namespace，在其中把存储重新挂一遍：

```text
/storage/emulated/0                     → /data/media/0/Android/data/<pkg>/sdcard   沙箱
/storage/emulated/0/DCIM                → /mnt/user/0/emulated/0/DCIM              共享目录
/storage/emulated/0/Android/data/<pkg>  → /mnt/user/0/emulated/0/Android/data/<pkg>
```

两组挂载会以两种方式丢失：

- **进程被杀**：进程一退出，它的 namespace 随之销毁，沙箱和共享目录一起消失；
  没有 umount 事件，应用重启、SI 重新建好 namespace 后通常能恢复。
- **FUSE 重挂**：ColorOS 等 ROM 清理后台时可能杀掉 MediaProvider，vold 会重挂用户存储，
  FUSE 设备号变化，应用 namespace 里挂在这层 FUSE 上的沙箱和共享目录整棵失效；
  进程还在，但应用看到的是真实存储（隔离失效），出现「视频已被删除」「图片发送失败」。

## 解决思路

- **事件驱动**：在 `path_mount` / `path_umount` 上挂 kprobe，阻塞读 `trace_pipe`；
  事件到达后合并 1 秒内的后续事件再扫描，空闲时阻塞等待。
  umount 侧回退 `ksys_umount` / `do_umount`，mount 侧回退 `ksys_mount` / `do_mount`。
- **启动自检**：私有 namespace 里真做一次 mount/umount，确认两侧事件都能到达；
  只看 tracefs 文件是否存在会被只读 tracefs 或裁剪内核骗过。
- **轮询降级**：tracefs 缺失、kprobe 注册失败、自检失败或事件通道被占用时自动转轮询，
  原因写入 `status.json`；tracefs/kprobe 恢复可用时会尝试切回事件模式，通道被占用则定期探测是否空闲。
- **身份与层保护**：沙箱根必须属于该包；沙箱所在设备号必须等于 FUSE 层设备号；
  源目录在宿主机和应用 namespace 里都必须可见。任何一条不满足就跳过，不猜着挂。
- **先验后拆、失败回滚**：修复前确认目标现状，bind 后校验设备号与挂载条数；
  校验不通过立即 umount 回滚，不留下“看起来挂上了”的坏状态。只有沙箱确实卸干净
  才会恢复临时卸下的普通 FUSE 根，且按原 root 恢复（root=`/` 用 `/storage/emulated`，
  root=`/0` 优先从 FUSE 层 `/0` 挂回），校验“一层、设备号、root”都等于原值才算挂回；
  卸不干净或恢复后对不上就保留现状并报 `rollback`。
- **重建沙箱的边界**：主扫描只在 `/storage/emulated/0` 栈顶是本包沙箱且只有一层时才认为
  健康；叠层/被其他层盖住会报 `rollback`/`sandbox_stale` 并提示重启应用。拆普通 FUSE 根
  只认本 boot、同 namespace、同进程（uid + `starttime` 都一致）的 `.sandbox_seen` 证据；
  没有同 ns 证据（升级后首次、同 boot 换了 namespace）时普通根（root=`/` 或 `/0`）不卸不
  bind，报 `sandbox_skip`，只补目标本来没有挂载（n=0）的包。
  本 boot 有该包任意 namespace 的行（或完全没有本 boot 记录）时，才允许这条“源存在+属主匹配”
  的回落；只有全部是别的 boot 的旧行才拒绝回落。旧格式的 `.sandbox_seen` 只有
  `pkg|boot|ns|SB` 四段，没有 uid/starttime 指纹，升级后按“无证据”处理（走上面的回落），
  不会因此放过真实丢失。
- **isolated 子进程不是隔离对象**：微信 `com.tencent.mm:xweb_sandboxed_process_0…`、浏览器
  sandboxed 进程等 uid 在 90000–99999 的 isolated 进程本来就没有 `/storage`，扫描直接跳过
  （不计 checked/broken、不发 G、不写 seen/退避）。漏到重建路径时，只有 isolated uid 或
  从未隔离过（本 boot 没有该包的 `.sandbox_seen` 证据）的进程才报 `na` 跳过、不写 180 秒
  退避；有 seen 证据的普通应用即使 namespace 里没有存储根，也仍按真实丢失尝试重建
  （普通根/退避路径不变）。普通应用 uid（10000–19999）不受影响。
- **失败退避**：修复失败按 (包, 目标) 记在 `.repairs`，180 秒内不再重试；key 带 FUSE 设备号、
  boot 和 namespace，任一变化立即失效。退避计时用 `/proc/uptime` 的单调时钟，系统时间被
  修改不会让退避提前到期或无限延长；没有单调时钟列、只有墙钟的失败行按“无退避”处理。沙箱重建与
  共享目录修复共用这套退避，RESULT 带 `retry=`（仍是剩余秒数），不会因为一次坏包每轮
  重复 bind/回滚。
- **PID/ns 再校验**：扫描时记下进程的 starttime（`/proc/<pid>/stat` 第 22 字段）、uid 和
  mount namespace；真正 bind/umount 前再读一次，任一不一致就跳过（`skipped=pid_changed`），
  不碰挂载。扫描到动手之间的极短窗口仍无法完全消除。
- **fail-closed**：配置读不出、FUSE 未就绪、目标在其他层时一律不动挂载；
  宁可这轮不修，也不把错误目录挂进应用。
- **FUSE 晚到 defer**：修复脚本取不到 FUSE 设备号时立即返回 `defer=fuse`，
  由守护进程按 1/2/4/8/15/30 秒退避重试；开机 180 秒内记 `boot_wait`，
  超时后记 `fuse_missing` 并每 60 秒继续重试。
- **churn 熔断**：同一 `(包名, 目标)` 在 300 秒内被修复 3 次，或距上次成功修复不到 1 秒，
  就暂停该目标，10 分钟后只重试一次；重试仍失败则锁定 1 小时，避免和 SI 反复抢挂载。
- **假活只提示不重建**：每 60 秒采样 kprobe 命中、`read events` 增量和 `last_event`；
  连续两个周期异常才标记 `blind`，提示重启手机，不擅自删除实例或 kprobe。

## 模块能力

- 运行模式：自动 / 事件 / 轮询，默认自动（事件可用则事件，否则轮询）。
- 开机自启：`service.sh` 拉起监督循环；守护退出后自动重启，状态长时间不更新时看门狗兜底。
- 修复与回滚：只修 SI 授权范围（允许目录与应用的 data/media/obb）；支持只读体检（`-n`）与详细模式（`-v`）。
- 进程范围：主进程与 `pkg:push` 这类常见子进程按 `ps args` 的基础包名匹配配置与身份，
  都能修复；同一包的不同 namespace 分别处理。uid 90000–99999 的 isolated 子进程（如微信
  xweb_sandboxed）不是 SI 隔离对象，直接跳过。
- 状态：`status.json`（含四类沙箱状态）、模块列表描述、WebUI 面板、模块「操作」按钮文本报告。
- 日志：`daemon.log`，超过 256 KB 轮转为 `daemon.log.1`；`.repairs` 每轮最多 200 行，启动/裁剪时清理 1 小时前的记录。
- WebUI：状态、配置、体检、立即修复、重启守护、应用与可访问目录比对、最近 40 行日志、桥接诊断。
- 兼容性检测：A15/A16/A17 使用同一份 `main.dex`（92,856 B / `2f3ca326…`），运行时按系统能力探测，
  用户确认后替换 `zygisk-storage-isolation` 的 `main.dex`；自动备份、校验并支持恢复，不动 SI 配置。
- 无桥接时仍可看：守护进程写 `webroot/snapshot.js`，任何 WebView 打开面板都能显示只读快照。
- 不联网，不写 `configuration.json`，不修改 SI 的隔离记录；卸载时清理守护、kprobe、trace 实例和数据目录
  （只要 `patch-backup` 里存在 `main.dex.*` 备份，就只保留该目录）。

## 安装与升级

**Magisk**：模块 → 从本地安装 → 选择 zip → 重启。`module.prop` 带 `updateJson`，
之后在模块页点更新即可按 `update.json` 从仓库拉新版本；zip 来自对应 tag 的 Release 资产。

**KernelSU / APatch**：模块 → 安装 → 选择 zip → 重启。两者使用各自管理器的模块安装入口，
不经过本模块 `META-INF/.../update-binary` 里的 Magisk 安装流程，也不读 `updateJson`；
升级时手动刷入新 zip 即可。

升级用同一个 zip 覆盖安装即可，配置与状态保存在 `/data/adb/si-mount-fix/`，升级不会清空；
卸载会删除该目录（只要 `patch-backup` 里存在 `main.dex.*` 备份，就只保留该目录）。安装后无需手动执行脚本。

**覆盖升级后要重启手机**（或在 WebUI 里点「重启守护」）：模块文件会立即替换，但正在运行的
守护进程要重启后才换成新代码。重启前，面板/「操作」按钮读到的仍是重启前的状态，
版本号却已经是新模块的——这属于正常现象。

**补丁状态**：兼容性检测只处理 `zygisk-storage-isolation/main.dex`。如果检测到 88,336 B /
`5413a01b6c49f360f3851af60be8820fcb8a4595d0c15697fcebac88b6d73891` 的 `main.dex`，
卡片显示为 `patched-legacy`；点「升级到通用版」时先备份为 `main.dex.legacy.<时间戳>`，再安装
通用 dex，已有原版备份保留。升级后重新 `check`，按卡片状态操作。

### 版本与更新检查

- 仓库：[lukka-hub/si-mount-fix](https://github.com/lukka-hub/si-mount-fix)，
  `update.json` 与 Release 资产都以这里为准。
- 当前版本：v2.0.1 / versionCode 2010；版本只有一个来源：`module.prop` 的 `version=v2.0.1`
  与 `versionCode=2010`。
- `updateJson` 指向仓库 `main` 分支的 `update.json`（Magisk 要求绝对 URL，相对路径拉不到）。
- `update.json` 按 Magisk 更新格式写：`version` / `versionCode` / `zipUrl` / `changelog`；
  `zipUrl` 指向对应 tag 的 GitHub Release 资产，发版时自动更新。`changelog` 指向
  [CHANGELOG.md](CHANGELOG.md)，只列当前版本的更新内容。

**打开面板**：KernelSU 管理器可在模块页打开 WebUI；Magisk 本体没有内建 WebUI，
需安装 **KsuWebUI Standalone** 后从其中打开本模块。没有 WebUI 时，点模块的「操作」按钮
也能看到模式、守护 PID、运行时长、体检结果和最近日志。

## 兼容性检测（main.dex）

**适用**：Android 15/16/17（SDK 35/36/37）+ Zygisk 模块 **zygisk-storage-isolation v29.0.1**
（versionCode 89，`main.dex`）。兼容性检测使用一份 `main.dex`（92,856 B / sha256
`2f3ca3263225d2577ab132e16dcc7273a61a80feea232b2f32e0100f6b3c8a22`）通配 Android 15/16/17，
向下兼容；运行时按系统能力探测，不按 SDK 拆资产。其它模块版本不要使用。

**现象**：SI 的应用列表为空，或隔离应用的导出规则、批量写入、Download 下载不生效。根因是
Android 17 的 `IPackageManager.getInstalledPackages` 返回类型从 `ParceledListSlice` 变成
`PackageInfoList`，旧调用解析不了；A15/A16 的列表仍走旧 `ParceledListSlice`，读列表不受影响。
`ServiceManager.getService2`、MediaProvider 导出规则、`applyBatch`、DownloadProvider 等路径在
原 dex 里没有被覆盖（见 [根因分析](docs/root-cause.md)）。

**为什么只补 main.dex**：SI 的 `daemon-v355` 每次启动（含开机）都会把内嵌原版写回自己的
server dex，补 server dex 每次开机都会被还原。`main.dex` 是持久的那一半：替换
`/data/adb/modules/zygisk-storage-isolation/main.dex` 后重启手机，server dex 虽被还原成
原版，列表/导出/批量/下载仍正常，且跨重启保持。

**状态颜色**：

| 颜色 | 状态 | 含义 |
|---|---|---|
| 黄 | 未注入/无法确认 | `original` 可应用；`patched-legacy`（88,336 B 旧补丁格式）可升级/恢复；`unknown` 可强制恢复（有有效原版备份且版本匹配时）；`no-target`/`unsupported` 显示原因，检查可用、动作按钮隐藏；模块版本不匹配时动作置灰 |
| 绿 | 已注入 | `patched`：通用 dex 已写入；重启手机后生效；版本匹配且有原版备份时可恢复；模块版本不匹配时仍为绿色（表示已注入），但动作置灰 |
| 红 | 错误 | 检查/读取失败或 apply/restore 失败；保留当前文件 |

**按 Android 版本恢复的能力**（同一份 dex，运行时探测；三个版本各自恢复的具体能力如下）：

**Android 15（SDK 35）**

- 应用列表：沿用旧 `ParceledListSlice` 路径，列表读取不受影响。
- MediaProvider 导出：accessible 目录与 observer 的 source→target 规则在 insert/update 中生效；
  `relative_path` 越界拒绝或改写；只有 `_data` 的 update fail-closed。
- applyBatch（仅 MediaProvider/DownloadProvider）：批量 insert/update 逐 op 改写，已导出文件不会再被移回源目录；带 back-reference
  的整批拒绝。
- DownloadProvider：`v.f` 规范化 hint、拒绝 `..`、target 幂等；`v.d` 按 `/my_downloads` 前缀匹配。
- ServiceManager：A15 release 不启用不存在的 `getService2`；QPR1/QPR2 按实际 `Service` union
  适配；只 hook `activity`/`vold`。
- 能力探测：类/方法缺失时回原路径或空跑，不改写非目标服务。

**Android 16（SDK 36）**

- 应用列表：旧 `ParceledListSlice` 兼容，列表读取不受影响。
- MediaProvider 导出：accessible 目录与 observer 的 source→target 规则在 insert/update 中生效；
  `relative_path` 越界拒绝或改写；只有 `_data` 的 update fail-closed。
- applyBatch（仅 MediaProvider/DownloadProvider）：批量 insert/update 逐 op 改写，已导出文件不会再被移回源目录；带 back-reference
  的整批拒绝。
- DownloadProvider：`v.f` 规范化 hint、拒绝 `..`、target 幂等；`v.d` 按 `/my_downloads` 前缀匹配。
- ServiceManager：`getService2` 返回 `Service`（`ServiceWithMetadata` union），`checkService` 为
  `IBinder`，`checkService2` 返回 `Service`；只 hook `activity`/`vold`。
- 能力探测：类/方法缺失时回原路径或空跑，不改写非目标服务。

**Android 17（SDK 37）**

- 应用列表：`PackageInfoList` → `List`，修复 SI 空列表。
- MediaProvider 导出：accessible 目录与 observer 的 source→target 规则在 insert/update 中生效；
  `relative_path` 越界拒绝或改写；只有 `_data` 的 update fail-closed。
- applyBatch（仅 MediaProvider/DownloadProvider）：批量 insert/update 逐 op 改写，已导出文件不会再被移回源目录；带 back-reference
  的整批拒绝。
- DownloadProvider：`v.f` 规范化 hint、拒绝 `..`、target 幂等；`v.d` 按 `/my_downloads` 前缀匹配。
- ServiceManager：`getService2`/`checkService2` 返回 `Service`，`checkService` 为 `IBinder`；
  只 hook `activity`/`vold`。
- 能力探测：类/方法缺失时回原路径或空跑，不改写非目标服务。

兼容层按系统能力探测，不按版本猜：a1 看 `getInstalledPackages` 的实际返回对象；u0 只在系统真的
调用到某个方法名时处理；u2 用反射先试 `getServiceWithMetadata`，失败再试 `getBinder`。类/方法
缺失时回原路径或空跑。三版共用同一份 dex；dex 内对 `PackageInfoList`、`android.os.Service`、
`ServiceWithMetadata` 的直接引用为 0。

**版本校验**：

- 原版 `main.dex`：90,740 B，sha256
  `a407674bba778267bac3d50bbdf528fa72fc219f46ef0463ad91bc58a56e82b9`
- 通用 `main.dex`：92,856 B，sha256
  `2f3ca3263225d2577ab132e16dcc7273a61a80feea232b2f32e0100f6b3c8a22`
- 旧版注入 `main.dex`：88,336 B，sha256
  `5413a01b6c49f360f3851af60be8820fcb8a4595d0c15697fcebac88b6d73891`

`check` 按 sha256 + 大小判断：`original`（可应用）、`patched`（已注入通用版）、
`patched-legacy`（旧版注入，`LEGACY=1`）、`unknown`（未知版本，拒绝操作）、
`no-target`（未装 zygisk 模块/没有 `main.dex`）、`unsupported`（SDK 不是 35/36/37）。

`apply` 和 `restore` 都会校验 zygisk 模块版本（`module.prop` 的 `siPatchVersion` /
`siPatchVersionCode`，当前为 v29.0.1 / 89；`siPatchModule` / `siPatchTarget` 提供模块名和
`main.dex`）。版本不匹配时：`apply` 拒绝执行，`restore` / `restore --force` 也拒绝，
面板的「强制恢复」不显示；哈希门禁仍然保留。模块 `module.prop` 读不到版本时，以目标
`main.dex` 存在本身作为适用范围依据。

**旧版注入升级**：`apply` 允许从 `patched-legacy` 升级到通用版：先把当前旧 dex 备份为
`patch-backup/main.dex.legacy.<时间戳>`（600），再安装通用版；原版备份（a407）保留不动。
`restore` 允许从 `patched-legacy` 直接恢复原版，但只认有效原版备份；没有原版备份时拒绝并
提示「缺少原版备份，可先升级到通用版」。升级/恢复成功都回到 `patched` / `original`，
`LEGACY` 回到 0。

**重启提示与标记**：apply/升级成功后写
`/data/adb/si-mount-fix/patch-pending-reboot`（600，内容为本次启动标识：优先 boot_id，缺失时用
当前时间减 `/proc/uptime` 秒数得到开机时刻）。`check` 输出 `PENDING_REBOOT`：启动标识一致为 1；
重启后标识变化则自动删除标记并输出 0。WebUI 的绿色“重启手机生效”只在 `PENDING_REBOOT=1` 时显示；
重启后打开面板不再出现。`restore` 成功后删除标记。`check` 只读 boot_id/uptime 两个定点文件，
不遍历 `/proc`。

**重启生效**：`main.dex` 由 Zygisk 模块在开机时加载，apply/restore 只写文件、不重启任何进程。
写入后必须重启手机；重启前 SI 仍在使用旧 dex。

**备份与恢复**：apply 先把原版备份到
`/data/adb/si-mount-fix/patch-backup/main.dex.<时间戳>`（权限 600），再把
`assets/main.dex` 复制到目标，`chown root:root`、`chmod 644`，校验 sha256 与大小后原子替换；
替换后会再校验一次，不符就用备份覆盖回去。恢复按时间从新到旧扫描备份，选第一份 sha256
等于原版的；当前是 `unknown` 但存在有效原版备份、且模块版本匹配时，才可以用「强制恢复」
（命令行 `restore --force`）。

**面板显示**：SDK 35/36/37 显示卡片；SDK 不在 35/36/37 时也显示 `unsupported` 原因（桥接可用时），
`apply`/`restore`/`force` 禁用、检查可用；`no-target` 显示「未检测到」；模块版本不匹配时显示卡片
但动作置灰；`unknown` 显示「未知版本」，只有版本匹配且存在有效原版备份时才显示「强制恢复」；
`original` 启用「应用补丁」，`patched` 启用「恢复原版」，`patched-legacy` 显示「旧版注入」并启用
「升级到通用版 / 恢复原版」。首次提示只在 `original` 且版本匹配时出现。动作按钮统一 44px 高、
同圆角/字号/间距；应用/升级为主按钮，恢复为次按钮，强制恢复仅红色边框/文字、不放大；
「检查补丁」与耗时文字同一行。

**在 WebUI 里操作**：

1. 首次打开面板、状态为 `original`（版本匹配）时，顶部会提示
   「兼容性检测：main.dex 未注入」。点「应用补丁」先进入确认（按钮需再点一次「确认注入」），
   确认框会显示目标模块版本和「仅适用于 v29.0.1（main.dex）」；点「暂不」不会改动任何文件。
   首次提示标记按目标文件+版本区分（`/data/adb/si-mount-fix/.patch_prompted.main.dex.v29.0.1`），
   点「暂不」或应用成功后才写，同一目标只提示一次；失败/超时不会写标记，下次打开仍会重新 check。
   手动入口在「兼容性检测（main.dex）」卡片里。
2. 应用/升级、恢复、强制恢复都是两步确认；确认后 10 秒内不操作会自动取消。
   `patched-legacy` 的确认框会说明“把旧版 main.dex 升级为通用版并备份当前 dex”。
3. 长动作在后台执行：体检/修复、重启守护、保存配置、apply/restore 都不会阻塞界面，
   apply/restore 成功后只做一次 `stat + sha256` 复核，不再跑第二次全量 `check`。
   成功提示“已应用，重启手机生效”或“已恢复原版，重启手机生效”；超时/读不到退出码时
   显示“结果未知，请刷新检查”，不会直接判失败或成功。动作失败/超时不会写状态缓存或提示
   标记，下次打开会重新 `check`；`check` 进行中应用/恢复/强制恢复按钮置灰并提示“检查中”。
4. 补丁状态有 30 秒缓存：30 秒内直接复用；过期后先比目标 mtime+size+sha，全部未变才复用，
   否则重跑 `check`。刷新不会每次都跑 `check`；需要强制重查时点卡片里的「检查补丁」；
   卡片会显示“检查 42ms / 检查超时（8 秒）”等耗时反馈。
5. 恢复：在卡片里点「恢复原版」，或运行 `restore`。

**命令行**（root）：

```sh
sh /data/adb/modules/si-mount-fix/scripts/si-patch.sh check    # 机器可读状态
sh /data/adb/modules/si-mount-fix/scripts/si-patch.sh status   # 一行状态
sh /data/adb/modules/si-mount-fix/scripts/si-patch.sh apply    # 应用（已应用则 no-op）
sh /data/adb/modules/si-mount-fix/scripts/si-patch.sh restore  # 恢复原版
sh /data/adb/modules/si-mount-fix/scripts/si-patch.sh restore --force  # unknown 时强制恢复
```

`check` 输出 `STATE` / `SDK` / `SDK_NAME` / `CAPS` / `SI_VERSION` / `SI_VERSION_CODE` /
`SI_TARGET_MODULE` / `SI_TARGET_VERSION` / `SI_TARGET_VERSION_CODE` / `SI_TARGET_FILE` /
`SI_MATCH` / `DEX` / `SIZE` / `MTIME` / `SHA` / `ORIGINAL_SIZE` / `ORIGINAL_SHA` /
`PATCH_SIZE` / `PATCH_SHA` / `BACKUP_COUNT` / `BACKUP_OK` / `PROMPTED` / `LEGACY` /
`PENDING_REBOOT` 二十四个 `KEY=VALUE`。任何状态都返回 0；
`apply`/`restore` 失败时非 0 退出，并在 stderr 说明原因。

**注意**：

- 不会自动应用：必须由用户点按钮并二次确认，或手动执行 `apply`。
- 没有可用原版备份时，`restore` 无法回退；`check` 的 `BACKUP_OK` 会显示 0。
  `patched-legacy` 缺少原版备份时会提示「缺少原版备份，可先升级到通用版」。
- 模块版本不匹配时不允许 `apply`/`restore`/`restore --force`，避免把别的模块版本覆盖坏。
- **上游覆盖**：官方更新 zygisk-storage-isolation 可能覆盖 `main.dex`，补丁会失效；更新后重新
  `check`，只有模块版本仍是 v29.0.1 且状态为 `original` 或旧版注入时才重新应用。版本变化后
  会显示 `unknown`，不要强行用旧的原版备份恢复。
- **卸载不会自动恢复 `main.dex`**：只要 `/data/adb/si-mount-fix/patch-backup/main.dex.*`
  存在，卸载时就只保留该目录并打印路径，其余运行期数据照旧删除；保留不依赖 `BACKUP_OK`
  或 `sha256sum` 是否可用（保守处理）。需要恢复请在卸载前运行 `restore --force`
  （模块版本匹配时）。
- 支持 SDK 35/36/37；其它 Android 版本 `check` 显示 `unsupported`，`apply` 直接拒绝。

**测试边界**：

- 自动化验证：A15/A17 模拟器 `dex2oat` 0 个 verification error、115/115 类加载；harness 58/58；
  baksmali→assemble 往返 byte-identical；禁止直接引用扫描 0。
- 未验证：A16、A15 QPR1/QPR2、真机、真机冷启动；真实 `IPackageManager`/PMS、真实
  MediaProvider/DownloadProvider 进程内 E2E、`applyBatch` 的真实 `onTransact`、`q0.b` 跨 uid
  update、Download E2E。
- **不包含**：`server-v355.dex`（原因见[根因分析](docs/root-cause.md)）、全局 activity 代理、
  逐包 `getPackageInfo`、多用户/工作资料。

## 配置

配置文件：`/data/adb/si-mount-fix/config.conf`。可在 WebUI 修改，保存后守护自动重启。

| 键 | 默认 | 说明 |
|---|---|---|
| `ENABLED` | `1` | `0` 停止守护（状态写“已停用”） |
| `MODE` | `auto` | `auto` / `event` / `poll` |
| `POLL_INTERVAL` | `60` | 轮询间隔，10~600 秒 |
| `MIN_AGE` | `15` | 最小进程年龄，5~120 秒 |

- `auto`：优先事件，环境不支持时自动降级轮询。
- `event`：要求事件模式；环境不支持时仍走轮询，并在原因后加 `+forced_event_unsupported`。
- `poll`：强制轮询，不尝试 kprobe。
- **轮询间隔只在轮询模式下有意义**：面板在 `auto`/`event` 下隐藏该字段，值仍保留在配置里。
- **`MIN_AGE` 两种模式都用**：太年轻的进程本轮跳过，并在 `MIN_AGE + 2` 秒后补扫一次，
  避免应用刚启动、挂载还没完成时被误判为故障。
- 配置缓存（`/data/adb/si-mount-fix/.conf.cache`）头里带解析器+修复脚本指纹；模块更新（含修复脚本/解析器）后旧缓存
  自动失效，不会继续沿用旧目录列表。

## 状态与上报

常用排查入口：

```sh
cat /data/adb/si-mount-fix/status.json
tail -n 50 /data/adb/si-mount-fix/daemon.log
sh /data/adb/modules/si-mount-fix/scripts/fix-si-mounts.sh -n      # 只读体检
sh /data/adb/modules/si-mount-fix/scripts/fix-si-mounts.sh -n -v   # 附带允许目录
sh /data/adb/modules/si-mount-fix/scripts/restart.sh               # 重启守护
```

`status.json` 同时提供 `reason`（机器可读）与 `reason_text`（中文短标签，面板/「操作」按钮直接用；
守护状态没有该字段时，两端保留一份兜底词表）。无桥接时用的只读快照 `webroot/snapshot.js` 里另带
`config{enabled,mode,interval,min_age}`，面板据此渲染配置。另有 `sandbox_gone` / `sandbox_stale` /
`sandbox_rollback` / `sandbox_skip` 四个 0/1 字段，表示最近一轮扫描的沙箱问题；最近一轮 fix
报错时可能仍是上一次的值。`last_fixed` 是“本次修复”的条数，每轮成功扫描都会按本轮 `fixed`
覆盖（0 也归零），累计值看 `total_fixed`。

`status.json` 的 `reason`：

| reason | 含义 / 处理 |
|---|---|
| `ok` | 正常 |
| `boot` | 启动中（`mode=starting`） |
| `disabled` | `ENABLED=0`，守护已停 |
| `tracefs_missing` | 没有可写 tracefs，已降级轮询 |
| `kprobe_failed` | kprobe 注册失败，已降级轮询 |
| `selftest_failed` | 事件自检失败，已降级轮询 |
| `pipe_busy` / `pipe_open_error` | 事件通道被占用 / 打不开；保持共享实例不动，降级轮询 |
| `pipe_closed` | 事件通道关闭，守护已停止 |
| `trace_reset` | `tracing_on` 被外部关闭，已重新打开 |
| `forced_poll` | 配置要求轮询 |
| `boot_wait` | 开机宽限期内等 FUSE，自动退避重试 |
| `fuse_missing` | 超过宽限期 FUSE 仍未就绪；fail-closed，每 60 秒重试 |
| `blind` | 事件通道假活；建议重启手机（不会自动重建） |
| `skipped_locked` | 上一轮修复未结束，本轮让路，2 秒后重试 |
| `launch_failed` | 守护启动失败，检查模块是否启用、`daemon.log` |
| `fix_error_*` | 修复脚本异常，`*` 为具体错误（如 `config`、`ps`、`timeout`） |
| `*+forced_event_unsupported` | 配置要求事件但环境不支持，已保守转轮询 |

## 注意事项与限制

1. **FUSE 可能晚到**：开机阶段状态会显示 `boot_wait`，这是等待而非故障；超过 180 秒才变
   `fuse_missing`。期间模块不会动任何挂载，FUSE 就绪后自动恢复扫描。
2. **依赖 tracefs / kprobe**：部分 ROM 的 tracefs 只读、内核裁掉挂载符号，或事件通道被其他
   工具占用；此时自动降级轮询，功能仍可用。
3. **fail-closed**：配置解析失败、身份不符、层不一致、源目录不可见时一律跳过。日志会说明原因，
   不会为了“修上”而乱挂目录。
4. **churn / block 是保护不是故障**：频繁被拆的目标会先等 10 分钟，重试仍失败锁定 1 小时；
   重启守护或模块会提前解除。
5. **不能恢复数据**：本模块只恢复挂载视图。文件已被删除、SI 隔离记录损坏、MediaProvider 的
   `relative_path` 写错，都不在修复范围内。
6. **Android 版本差异**：只支持 FUSE 存储（Android 11+）；Android 10 及更早的 `sdcardfs`
   设备不处理。仅处理主用户（user 0），工作资料/多用户进程直接跳过。
   13~16 的命令/接口面已按 AOSP/toybox 源码核对，但未逐版本实机；17 为当前实机验证。
   OEM 内核/SELinux 限制 kprobe 时会自动降级轮询。
7. **SI 私有格式可能变化**：`configuration.json` 的字段由 SI 决定，解析失败时模块会跳过本轮，
   表现是“在跑但没动作”，而不是误挂。
8. **假活需重启**：`blind=1` 表示 kprobe 在响但事件读不到，当前版本只提示，不自动重建通道。
9. **沙箱问题需重启应用**：`sandbox_stale`/`sandbox_rollback`/`sandbox_skip` 分别表示僵死、
   回滚或叠层残留、安全跳过；模块不会原地强拆，重启该应用让 SI 重建 namespace 即可收敛。
10. **root=`/0` 的普通根**：少数设备的 `/storage/emulated/0` 普通 FUSE 根，mountinfo 里的
    root 是 `/0`；回滚时会按原 root（`/` 用 `/storage/emulated`，`/0` 优先从 FUSE 层
    `/0` 挂回、应用看不到时退回 self-bind）恢复，并校验层数、设备号与 root 都与原值一致，
    不一致就按 `rollback` 保留现状，不会谎报已恢复。
11. **禁用模块不等于立即停止**：已运行的守护要到下次重启才消失；要立刻停止请卸载或手动结束进程。

## 排障

- 微信仍提示文件不存在：先看 `status.json` 的 `reason` 和 `procs`；若 `procs=0` 或体检 `checked=0`，确认设备是
  FUSE 存储、SI 增强模式已启用、应用在主用户下；再跑 `fix-si-mounts.sh -n -v` 看允许目录是否解析正确。
- 视频/图片突然读不到，且体检出现 `skipped=*sandbox_gone*`：ColorOS 上 MediaProvider 被杀后
  vold 会重挂 FUSE，应用 namespace 里的沙箱和共享目录会一起消失。模块会在下一轮**尝试**重建沙箱并补回挂载
  （源目录存在且属主匹配才动手）；重建成功后 WebUI 的修复结果会显示“重建沙箱 N 个”。失败后 180 秒内
  不再重试，RESULT 会带 `retry=`，所以短时间反复体检看到同一个包是正常的。同一事件的日志只记一次
  （形如 `沙箱丢失: <包> (pid=… uid=… ns=… reason=… isolated=…, 下一轮重试)`），退避/重试期间不会
  每轮重复刷屏；应用自愈、事件从本轮报告消失后签名会被清掉，下一次真丢会重新记一条。若这个标记
  持续出现，说明 MediaProvider 被反复杀，检查系统的省电/后台策略，并附上 `daemon.log`、
  `status.json` 反馈。
- 出现 `skipped=*sandbox_skip*`：包在跑、沙箱却丢了，但本 boot 没有该包同 namespace 的
  `.sandbox_seen` 证据，而 `/storage/emulated/0` 还是普通 FUSE 根；或者目标被别的挂载层
  占用（例如残留的 f2fs bind）。这时拆根/重建可能挂错目录，模块会 fail-closed：不卸不 bind，
  也不会按 180 秒重试。**重启该应用**让 SI 重建 namespace；下一次健康扫描登记证据后再丢沙箱
  才会自动重建。它和 `sandbox_gone`（可尝试重建）不是一回事。
- 出现 `skipped=*na*`：进程是 uid 90000–99999 的 isolated 子进程（如微信 xweb_sandboxed），
  或它从未被隔离过（本 boot 没有该包的 `.sandbox_seen` 证据）且 namespace 里连 `/storage`
  都没有，不是 SI 的隔离对象。模块只报 `na` 并在日志写“isolated/无 storage，跳过”，不写
  退避、不计需修复；这属于正常现象，不用处理。有 seen 证据的普通应用不会落到这里。
- 出现 `skipped=*rollback*`：沙箱 `umount` 没卸干净、原 FUSE 根恢复失败，或主扫描发现
  `/storage/emulated/0` 叠了多层。模块保留残留挂载，不会为了“看起来修好了”把父根叠回去，
  也不会自动重试。**重启该应用**即可收敛；不要反复点修复。
- 出现 `skipped=*target_missing*`：沙箱锚点/目标目录不存在（`/data/media` 下的沙箱副本、
  或 `Android/{data,media,obb}` 目标），模块不会硬 bind，会说明缺的是哪个路径并计入需修复。
  多为 SI 的沙箱目录被清掉，重启该应用让 SI 重建后再看。
- 出现 `skipped=*pid_changed*`：扫描之后、动手之前进程重启或换了 namespace；模块跳过本轮、
  不 bind/umount，下一轮按新进程重新扫描即可。
- 出现 `skipped=*sandbox_stale*`：应用 namespace 里还是旧 FUSE 的僵死挂载（宿主设备号已变、旧会话不存在，
  应用内读目录会报 `Transport endpoint is not connected`），或 target 栈顶被别的层盖住（不是本包沙箱）；
  回滚/原根恢复失败也归到这里。跨 namespace 无法修复，模块不会动挂载；重启该应用，让 SI 重建
  namespace 即可。`sandbox_gone` 会尝试重建，`sandbox_stale` 只能重启应用，两者不要混为一谈。
- 排查沙箱问题以模块「操作」按钮/体检输出为准（含包名和跳过原因）；`status.json` 另提供
  `last_sandbox`/`total_sandbox` 等计数（面板不单独展示）。其中
  `sandbox_gone`/`sandbox_stale`/`sandbox_rollback`/`sandbox_skip` 会显示在「操作」按钮和
  WebUI 主状态卡/banner（最近一轮 fix 报错时会标成“上次记录”）；`rollback`/`sandbox_stale`/
  `sandbox_skip` 都表示需要重启应用，不能只靠反复修复。
- **只有旧 boot 记录时不兜底**：某个包在 `.sandbox_seen` 里只剩别的 boot 的行、本 boot 一行
  都没有时，模块不拿它当重建资格；要等它下一次被识别为健康沙箱（K）并登记本 boot 的
  同 namespace + uid/starttime 证据后才恢复自愈。本 boot 有该包任意 namespace 的行时，仍允许
  n=0 的“源+属主”回落（同 namespace 优先；普通根仍按上面的规则不拆）。这是有意的
  fail-closed，不是丢状态。旧格式（`pkg|boot|ns|SB` 四段、没有 uid/starttime）的行
  按“无证据”处理，自动回落到“源存在 + 属主匹配”，不会把真实丢失一起放过。
- `-n` 是只读体检：不写 `.sandbox_seen`/`.fuse_dev`，不改挂载；判定与真跑一致（哪些进程
  需要修复、哪些报 `na` 不写退避），只是不动挂载。已有 `.sandbox_seen` 里的旧格式/空 ns
  行也只在非 `-n` 运行（持锁）时清理。升级/重启后的第一次自动扫描才会登记身份。
- 面板打不开：Magisk 需 KsuWebUI Standalone；没有桥接时面板会显示只读快照。也可直接用模块「操作」按钮。
- 「操作」按钮体检超过 40 秒或拿不到结果行时显示“执行失败（无结果行）”，不要当成“没有需要修复”；
  先看 `daemon.log` 和 `status.json`。
- `blind=1`：重启手机恢复事件投递；重启后仍是 `blind`，把 `daemon.log` 和 `status.json` 一起反馈。
- `churn>0`：等 10 分钟自动重试，或点「重启守护」清除熔断状态；仍反复出现说明 SI 在持续重挂，
  应连同日志反馈，而不是反复手动修复。
- `fuse_missing`：多为开机 FUSE 服务异常；先重启，仍不恢复则检查系统存储服务，模块会持续 fail-closed。
- 守护没运行：确认模块已启用、`ENABLED=1`，然后重启手机或执行 `restart.sh`。

## 文档

- [根因分析](docs/root-cause.md)
- [更新日志](CHANGELOG.md)

## 作者

宴生

## License

MIT（完整文本见 [LICENSE](LICENSE)）。
