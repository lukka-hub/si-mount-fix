# Storage Isolation Mount Fix

给 **Storage Isolation / 存储空间隔离**（`moe.shizuku.redirectstorage`）补回丢失的共享目录挂载。

支持 Android 13~17，**Magisk / KernelSU**。只补挂载：不修改 SI 的
`configuration.json`，不联网，不收集数据。

## 问题与根因

SI 的增强模式会为每个被隔离应用准备独立的 mount namespace，在其中把存储重新挂一遍：

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
  校验不通过立即 umount 回滚，不留下“看起来挂上了”的坏状态。
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
- 状态：`status.json`、模块列表描述、WebUI 面板、模块「操作」按钮文本报告。
- 日志：`daemon.log`，超过 256 KB 轮转为 `daemon.log.1`；`.repairs` 每轮最多 200 行，启动/裁剪时清理 1 小时前的记录。
- WebUI：状态、配置、体检、立即修复、重启守护、应用与可访问目录比对、最近 40 行日志、桥接诊断。
- 无桥接时仍可看：守护进程写 `webroot/snapshot.js`，任何 WebView 打开面板都能显示只读快照。
- 不联网，不写 `configuration.json`，不修改 SI 的隔离记录；卸载时清理守护、kprobe、trace 实例和数据目录。

## 安装与升级

**Magisk**：模块 → 从本地安装 → 选择 zip → 重启。模块的 `module.prop` 带 `updateJson`，
Magisk 管理器会按 `update.json` 提示新版本。

**KernelSU / APatch**：模块 → 安装 → 选择 zip → 重启。两者使用各自管理器的模块安装入口，
不经过本模块 `META-INF/.../update-binary` 里的 Magisk 安装流程，也不读 `updateJson`；
升级时手动刷入新 zip 即可。

升级用同一个 zip 覆盖安装即可，配置与状态保存在 `/data/adb/si-mount-fix/`，升级不会清空；
卸载会删除该目录。安装后无需手动执行脚本。

**覆盖升级后要重启手机**（或在 WebUI 里点「重启守护」）：模块文件会立即替换，但已经在运行的
旧守护进程要重启后才换成新代码。重启前，面板/「操作」按钮读到的仍是旧守护写下的状态
（没有 `reason_text`、快照里没有 `config`），版本号却已经是新模块的——这属于正常现象。

### 版本与更新检查

- 版本只有一个来源：`module.prop` 的 `version=v1.4.0` 与 `versionCode=140`
  （规则 `versionCode = major*100 + minor*10 + patch`）。
- `updateJson` 指向仓库 `main` 分支的 `update.json`（Magisk 要求绝对 URL，相对路径拉不到）。
- `update.json` 按 Magisk 更新格式写：`version` / `versionCode` / `zipUrl` / `changelog`；
  `zipUrl` 指向对应 tag 的 GitHub Release 资产，发版时自动更新。

**打开面板**：KernelSU 管理器可在模块页打开 WebUI；Magisk 本体没有内建 WebUI，
需安装 **KsuWebUI Standalone** 后从其中打开本模块。没有 WebUI 时，点模块的「操作」按钮
也能看到模式、守护 PID、运行时长、体检结果和最近日志。

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
`config{enabled,mode,interval,min_age}`，面板据此渲染配置。

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
9. **禁用模块不等于立即停止**：已运行的守护要到下次重启才消失；要立刻停止请卸载或手动结束进程。

## 排障

- 微信仍提示文件不存在：先看 `status.json` 的 `reason` 和 `procs`；若 `procs=0` 或体检 `checked=0`，确认设备是
  FUSE 存储、SI 增强模式已启用、应用在主用户下；再跑 `fix-si-mounts.sh -n -v` 看允许目录是否解析正确。
- 视频/图片突然读不到，且体检或 `status.json` 出现 `skipped=*sandbox_gone*`：ColorOS 上 MediaProvider 被杀后
  vold 会重挂 FUSE，应用 namespace 里的沙箱和共享目录会一起消失。模块会在下一轮自动重建沙箱并补回挂载，
  不需要重启应用；若这个标记持续出现，说明 MediaProvider 被反复杀，检查系统的省电/后台策略，并附上
  `daemon.log`、`status.json` 反馈。
- 面板打不开：Magisk 需 KsuWebUI Standalone；没有桥接时面板会显示只读快照。也可直接用模块「操作」按钮。
- `blind=1`：重启手机恢复事件投递；重启后仍是 `blind`，把 `daemon.log` 和 `status.json` 一起反馈。
- `churn>0`：等 10 分钟自动重试，或点「重启守护」清除熔断状态；仍反复出现说明 SI 在持续重挂，
  应连同日志反馈，而不是反复手动修复。
- `fuse_missing`：多为开机 FUSE 服务异常；先重启，仍不恢复则检查系统存储服务，模块会持续 fail-closed。
- 守护没运行：确认模块已启用、`ENABLED=1`，然后重启手机或执行 `restart.sh`。

## 文档

- [根因分析](docs/root-cause.md)
- [演化过程](HISTORY.md)

## 作者

宴生

## License

MIT
