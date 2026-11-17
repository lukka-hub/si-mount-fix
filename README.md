# Storage Isolation Mount Fix

给 **Storage Isolation / 存储空间隔离**（`moe.shizuku.redirectstorage`）补回丢失的共享目录挂载。

支持 Android 13~17，**Magisk / KernelSU**。默认只补挂载：不修改 SI 的
`configuration.json`，不联网，不收集数据。另有一个需用户确认的 Android 17 可选补丁，
只替换 SI 的 `server-v355.dex`（见「Android 17 应用列表修复」）。

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
  只认本 boot、同 namespace 的 `.sandbox_seen` 证据；没有同 ns 证据（升级后首次、同 boot
  换了 namespace）时普通根（root=`/` 或 `/0`）不卸不 bind，报 `sandbox_skip`，只补目标本来
  没有挂载（n=0）的包。
  本 boot 有该包任意 namespace 的行（或完全没有历史记录）时，才允许这条“源存在+属主匹配”
  的回落；只有全部是别的 boot 的旧行才拒绝回落。
- **失败退避**：修复失败按 (包, 目标) 记在 `.repairs`，180 秒内不再重试；key 带 FUSE 设备号、
  boot 和 namespace，任一变化立即失效。退避计时用 `/proc/uptime` 的单调时钟，系统时间被
  修改不会让退避提前到期或无限延长；旧版本只写墙钟的失败行按“无退避”处理。沙箱重建与
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
  都能修复；同一包的不同 namespace 分别处理。
- 状态：`status.json`（含四类沙箱状态）、模块列表描述、WebUI 面板、模块「操作」按钮文本报告。
- 日志：`daemon.log`，超过 256 KB 轮转为 `daemon.log.1`；`.repairs` 每轮最多 200 行，启动/裁剪时清理 1 小时前的记录。
- WebUI：状态、配置、体检、立即修复、重启守护、应用与可访问目录比对、最近 40 行日志、桥接诊断。
- Android 17 可选补丁：SDK 37 下 SI 应用列表为空时，用户确认后用一个自建补丁 dex 替换
  `server-v355.dex`；自动备份、校验并支持恢复，不动 `main.dex` 与 SI 配置。
- 无桥接时仍可看：守护进程写 `webroot/snapshot.js`，任何 WebView 打开面板都能显示只读快照。
- 不联网，不写 `configuration.json`，不修改 SI 的隔离记录；卸载时清理守护、kprobe、trace 实例和数据目录。

## 安装与升级

**Magisk**：模块 → 从本地安装 → 选择 zip → 重启。`module.prop` 带 `updateJson`，
之后在模块页点更新即可按 `update.json` 从仓库拉新版本；zip 来自对应 tag 的 Release 资产。

**KernelSU / APatch**：模块 → 安装 → 选择 zip → 重启。两者使用各自管理器的模块安装入口，
不经过本模块 `META-INF/.../update-binary` 里的 Magisk 安装流程，也不读 `updateJson`；
升级时手动刷入新 zip 即可。

升级用同一个 zip 覆盖安装即可，配置与状态保存在 `/data/adb/si-mount-fix/`，升级不会清空；
卸载会删除该目录。安装后无需手动执行脚本。

**覆盖升级后要重启手机**（或在 WebUI 里点「重启守护」）：模块文件会立即替换，但已经在运行的
旧守护进程要重启后才换成新代码。重启前，面板/「操作」按钮读到的仍是旧守护写下的状态，
版本号却已经是新模块的——这属于正常现象。

### 版本与更新检查

- 仓库已迁到 [lukka-hub/si-mount-fix](https://github.com/lukka-hub/si-mount-fix)，
  `update.json` 与 Release 资产都以这里为准。
- 版本只有一个来源：`module.prop` 的 `version=v1.5.2` 与 `versionCode=152`
  （规则 `versionCode = major*100 + minor*10 + patch`）。
- `updateJson` 指向仓库 `main` 分支的 `update.json`（Magisk 要求绝对 URL，相对路径拉不到）。
- `update.json` 按 Magisk 更新格式写：`version` / `versionCode` / `zipUrl` / `changelog`；
  `zipUrl` 指向对应 tag 的 GitHub Release 资产，发版时自动更新。`changelog` 指向
  [CHANGELOG.md](CHANGELOG.md)，只放当前版本的更新内容，不把整篇演化历史展示给管理器。

**打开面板**：KernelSU 管理器可在模块页打开 WebUI；Magisk 本体没有内建 WebUI，
需安装 **KsuWebUI Standalone** 后从其中打开本模块。没有 WebUI 时，点模块的「操作」按钮
也能看到模式、守护 PID、运行时长、体检结果和最近日志。

## Android 17 应用列表修复（可选补丁）

**适用**：Android 17（SDK 37）+ Storage Isolation **8.8.1 r3684**（`server-v355`）。
其它 SI 版本不要使用。

**现象**：SI 的应用列表为空（其它地方能看到已安装应用，SI 里一个都没有）。根因是
Android 17 改了 AIDL 返回类型 `PackageInfoList`，旧 `server-v355.dex` 解析不了新系统
返回的数据。替换这个 dex 后列表恢复；本机实测从 17 个恢复到 31 个。

**鸣谢**：思路由酷安用户「无所事事」提供。

**来源**：模块内的 `assets/server-v355.dex` 由本模块对官方 SI v355 的
`server-v355.dex` 自行反编译并重打。补丁只替换
`/data/adb/storage-isolation/bin/server-v355.dex`，不改 `main.dex`、不改 SI 配置、
不动 SI 的其它文件。补丁在用户确认后由模块写入。

**版本校验**：

- 原版 `server-v355.dex`：331,520 B，sha256
  `c410e8924da1a08f8fe05d8e5d36cae5eb1cb6a192bca219f9b940471db08d7a`
- 自建补丁：325,984 B，sha256
  `7a941f35ee893f187f4b1c59995b43af0a1f9c12d3988dda0ea519d324c82bbe`

`check` 按 sha256 判断：`original`（可应用）、`patched`（已应用）、`unknown`
（既非原版也非补丁，拒绝操作）、`no-si`（未装/无 server）、`unsupported`
（SDK 不是 37）。

`apply` 前还会校验 SI versionName 前缀（适用版本由 `module.prop` 的 `siPatchVersion` /
`siPatchServer` 提供，当前为 8.8.1 r3684 / server-v355）。版本不匹配时只提示、不执行，
哈希门禁仍然保留。versionName 读不到时，以固定路径 `server-v355.dex` 作为适用范围依据。

### 反编译改动

本模块对官方 SI v355 的 `server-v355.dex` 自行反编译并重打，只改 4 条指令：

1. `IPackageManager.getInstalledPackages(JI)` 的返回类型：`ParceledListSlice` → `PackageInfoList`
2. `IPackageManager.getInstalledPackages(II)` 的返回类型：`ParceledListSlice` → `PackageInfoList`
3. 第一处 `ParceledListSlice.getList()` → `PackageInfoList.getList()`
4. 第二处 `ParceledListSlice.getList()` → `PackageInfoList.getList()`

其余 386 类、1635 方法（1634 个方法体完全一致）、806 字段不变；新增字符串只有
`Landroid/content/pm/PackageInfoList;`。

为控制体积，重打包时剥离了调试信息（不影响运行逻辑，只影响崩溃堆栈行号）；
因此体积 325,984 B，与原版 331,520 B 接近。

**自动重启 SI server**：apply/restore 成功后会查找映射 `server-v355.dex` 的进程，只结束这些
进程（先 TERM 再 KILL），SI daemon 会在约 3 秒内用新 dex 重启 server；不会杀 daemon 或应用。
最多等 5 秒，失败只提示重开 SI/重启手机，不回滚已经写好的 dex。

**面板显示**：Android SDK 不是 37、或没有安装 SI 时，整张补丁卡片隐藏；SDK 37 但 SI 版本/哈希
不在支持范围时显示卡片但按钮置灰；当前不是原版且存在有效原版备份时，可用「强制恢复」；
只有版本匹配且状态为 `original` 才启用「应用补丁」，`patched` 才启用「恢复原版」。
首次提示也只在 SDK 37 且版本匹配时出现。

**在 WebUI 里操作**：

1. 首次打开面板、SDK 为 37 且状态为 `original`（版本匹配）时，顶部会提示
   「Android 17 应用列表可能为空」。
   点「应用补丁」先进入确认（按钮需再点一次「确认应用」），确认框会显示目标 SI 版本和
   「仅适用于 8.8.1.r3684（server-v355）」；点「暂不」不会改动任何文件。首次提示后会写
   `/data/adb/si-mount-fix/.patch_prompted`，之后不再自动弹，手动入口在
   「Android 17 应用列表修复」卡片里。
2. 应用、恢复、强制恢复都是两步确认；确认后 10 秒内不操作会自动取消。
3. 应用时先把原版备份到
   `/data/adb/si-mount-fix/patch-backup/server-v355.dex.<时间戳>`（权限 600），
   再把模块 `assets/server-v355.dex` 复制到目标，`chown root:root`、`chmod 600`，
   校验 sha256 后原子替换；替换后会再校验一次，不符就用备份覆盖回去。
4. 应用/恢复成功后会自动重启 SI server，通常不用手动重开；若列表没有刷新，再重开 SI 或
   重启手机。已应用状态会显示「已应用，可恢复原版」。
5. 恢复：在卡片里点「恢复原版」，或运行 `restore`。恢复会按时间从新到旧扫描备份，
   选第一份 sha256 等于原版的；当前是 `unknown` 但存在有效原版备份时，卡片会提供
   「强制恢复」（命令行 `restore --force`），需要显式确认。

**命令行**（root）：

```sh
sh /data/adb/modules/si-mount-fix/scripts/si-patch.sh check    # 机器可读状态
sh /data/adb/modules/si-mount-fix/scripts/si-patch.sh status   # 一行状态
sh /data/adb/modules/si-mount-fix/scripts/si-patch.sh apply    # 应用（已应用则 no-op）
sh /data/adb/modules/si-mount-fix/scripts/si-patch.sh restore  # 恢复原版
sh /data/adb/modules/si-mount-fix/scripts/si-patch.sh restore --force  # unknown 时强制恢复
```

`check` 输出 `STATE` / `SDK` / `SI_VERSION` / `SI_TARGET_VERSION` / `SI_TARGET_SERVER` /
`SI_MATCH` / `DEX` / `SIZE` / `SHA` / `BACKUP_COUNT` / `BACKUP_OK` / `PROMPTED`
十二个 `KEY=VALUE`。任何状态都返回 0；`apply`/`restore` 失败时非 0 退出，并在 stderr
说明原因。

**注意**：

- 不会自动应用：必须由用户点按钮并二次确认，或手动执行 `apply`。
- 没有可用原版备份时，`restore` 无法回退；`check` 的 `BACKUP_OK` 会显示 0。
- SI 更新可能覆盖 `server-v355.dex`，补丁会失效；更新后重新 `check`，按需再次应用。
- 卸载模块时会先尝试恢复原版 dex；恢复成功才删除 `/data/adb/si-mount-fix/`。恢复失败时
  会保留该目录（含 `patch-backup`）并打印路径，不会静默删掉备份。
- 只支持 SDK 37；其它 Android 版本 `check` 显示 `unsupported`，`apply` 直接拒绝。

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
旧版守护没有该字段时，两端保留一份兜底词表）。无桥接时用的只读快照 `webroot/snapshot.js` 里另带
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
  不再重试，RESULT 会带 `retry=`，所以短时间反复体检看到同一个包是正常的。若这个标记持续出现，
  说明 MediaProvider 被反复杀，检查系统的省电/后台策略，并附上 `daemon.log`、`status.json` 反馈。
- 出现 `skipped=*sandbox_skip*`：包在跑、沙箱却丢了，但本 boot 没有该包同 namespace 的
  `.sandbox_seen` 证据，而 `/storage/emulated/0` 还是普通 FUSE 根；或者目标被别的挂载层
  占用（例如残留的 f2fs bind）。这时拆根/重建可能挂错目录，模块会 fail-closed：不卸不 bind，
  也不会按 180 秒重试。**重启该应用**让 SI 重建 namespace；下一次健康扫描登记证据后再丢沙箱
  才会自动重建。它和 `sandbox_gone`（可尝试重建）不是一回事。
- 出现 `skipped=*rollback*`：沙箱 `umount` 没卸干净、原 FUSE 根恢复失败，或主扫描发现
  `/storage/emulated/0` 叠了多层。模块保留残留挂载，不会为了“看起来修好了”把父根叠回去，
  也不会自动重试。**重启该应用**即可收敛；不要反复点修复。
- 出现 `skipped=*target_missing*`：沙箱锚点目录或目标目录不存在（`/data/media` 下的沙箱副本、
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
  同 namespace 证据后才恢复自愈。本 boot 有该包任意 namespace 的行时，仍允许 n=0 的
  “源+属主”回落（同 namespace 优先；普通根仍按上面的规则不拆）。这是有意的 fail-closed，
  不是丢状态。
- `-n` 是只读体检：不写 `.sandbox_seen`/`.fuse_dev`，不改挂载；已有 `.sandbox_seen` 里的
  旧格式/空 ns 行也只在非 `-n` 运行（持锁）时清理。升级/重启后的第一次自动扫描才会登记身份。
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
- [演化过程](HISTORY.md)

## 作者

宴生

## License

MIT
