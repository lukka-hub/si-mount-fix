# 演化过程（1.0 → 1.5.2）

> 说明：1.0~1.3.1 的提交是根据早期文档与发布产物回溯的说明，原始源码没有保留；
> 1.3.2 起是真实代码提交。1.3.3 未形成单独的发布 tag，1.3.4 接续。

## 1.0 第一代：纯脚本补挂载

- 发现 SI 在应用 mount namespace 里只保留沙箱 bind；
- `fix-si-mounts.sh` 扫描 `/proc/*/mountinfo`，按需补齐共享目录。

## 1.1 修正来源层：f2fs 裸盘 → FUSE

- 补出来的挂载设备号是 `254:37`（f2fs），SELinux 不允许 untrusted_app 读；
- 来源改为 `/mnt/user/0/emulated/0/...`；
- 新增层校验：目标设备号必须等于沙箱设备号，否则拆掉重挂。

## 1.2 事件驱动 + 扫描提速

- `si-mount-eventd.sh`：kprobe(path_mount/path_umount) + 单独的 trace 实例 +
  `trace_pipe` 阻塞读；
- 内核 filter 排除 nsenter/magiskd，防止部分自触发；mount/umount 自身的事件靠事件 drain 吸收（1.4.0 起 filter 再补这两类）；
- 先按授权包名筛候选进程，扫描从 7.5s 降到约 0.23s；
- 保留 watchdog 轮询作为备选。

## 1.3 工程化

- 授权只来自 `configuration.json`；
- 沙箱识别必须形如 `/<user>/Android/data/<pkg>/sdcard`；
- 只处理存活 ≥15s 的进程；
- 重挂前循环拆干净，挂后校验设备号/条数，失败回滚；
- 单实例锁；多用户按 uid 取 FUSE 源。

## 1.3.1 第一个可刷入产物

- 打包为 Magisk 模块：`module.prop`、`action.sh`、`webroot/` 面板等；
- 作为后续代码基线的前身。

## 1.3.2 基线修复

- 面板全空/守护自杀问题修复；
- 成为当前 Git 代码历史的起点。

## 1.3.4 身份/开机/事件通道

- 身份校验、开机 FUSE 等待、`pipe_busy` 时不拆共享实例。

## 1.3.5 全扫提速 + 熔断 + 假活

- 单次 `ps | awk`、配置缓存、ms 级 churn、FUSE 等待、blind 检测。

## 1.3.6 FUSE defer

- 不再固定等 20 秒；fix 立即 `defer=fuse`，daemon 在开机宽限期退避重试；
- 区分 `boot_wait` / `fuse_missing`，修复事件风暴饿死重试。

## 1.3.7 修复 Magisk 体检

- action 环境 busybox `ps` 不支持 `-o uid`；固定系统 PATH/PS，体检不再误报 `error=ps`。

## 1.3.8 UI 减法

- 去掉重复的「运行模式」；「状态原因」→「状态上报」；
- 事件/自动模式隐藏轮询间隔；保留最小进程年龄。

## 1.3.9 发布定稿

- 发布文档、注释精简、作者署名；
- 同包多 PID churn 修复（CAND/BADK + fixed 去重）；
- 体检文案、reason 标签、FUSE/失败提示修正。

## 1.4.0 工程化收口

- **配置解析统一**：新增 `scripts/si-config.awk` 作为唯一解析实现，fix 与 list-apps 共用；
  压缩/多行 JSON、冒号逗号空白都支持，`packages` / `apps` 两种顶层字段都接受；
  fail-closed：显式 `enabled:false` 或非布尔值跳过，缺省保持启用（兼容旧配置）；
  未知模板、目录名含空格/`|`/引号等无法安全表示的一律跳过并打 `skipped=` 标签。
- **状态契约**：`status.json` 增加 `reason_text`（中文短标签，单一词表；带
  `+forced_event_unsupported` 后缀时先翻基础原因再追加后缀），只读快照增加
  `config{enabled,mode,interval,min_age}`；selftest/kprobe 失败改为 600 秒退避重试事件模式，
  poll 循环消费 `RETRY_AT` 的补扫时间，`young` 不再靠下一个事件触发。
- **daemon 边角**：kprobe filter 增加 `comm != mount/umount` 防自触发（自检期间先放宽、
  通过后才写最终 filter，否则自检会过滤掉自己的事件）；tracefs 恢复判据与启动一致（必须可写）；
  假活检测只在有真实流量时恢复；管道占用/重建路径的探测子进程及时回收。
- **打包**：版本号与包内文件白名单、可执行位等做前置校验，校验失败不产出半成品。
- **发布**：推送 `v*` tag 时校验版本一致并自动发布 Release。
- **测试与卸载**：修复脚本与守护之间的 RESULT 行格式收敛到一处，配置解析、状态优先级等
  补了用例；`uninstall.sh` 改为按 cmdline 精确匹配，不再宽泛 `pkill -f`。
- **WebUI / 操作**：状态展示统一走 `reason_text`，`churn`/`blind`/停用场景正确呈现；
  桥接失败会重置并回退只读快照（重新探测复用同一个 Promise，避免并发探测的旧结果把界面
  打回只读）；配置写入保留未知行并原子替换；补齐可访问性（`h1`、`aria-live`、
  `:focus-visible`、`aria-label`）。

## 1.4.1 沙箱丢失检测与重建

- **检测**：以前识别到过合法沙箱的包登记在 `.sandbox_seen`；这些包的进程在跑、年龄达标、
  配置里仍启用，但 `mountinfo` 里没有沙箱挂载时，判定为 `sandbox_gone`。
- **自愈**：非 dry 时把 FUSE 沙箱源 bind 回 `/storage/emulated/0`，校验设备号是当前 FUSE、
  条数为 1、source 指向该包沙箱后，再复用 `repair_one` 补 allow 目录与
  `Android/{data,media,obb}/<pkg>`；任何一步不满足就 `umount -l` 回滚。不杀进程、不改 SI 配置。
- **报告**：RESULT 增加 `sandbox=N`；重建失败或 dry-run 报 `skipped=sandbox_gone`，
  从未见过沙箱的包保持静默。`.fuse_dev` 记录本轮 FUSE 设备号供排障。
- **僵死区分**：沙箱本身是 FUSE、设备号不等于宿主 FUSE、且旧设备已不在宿主 mountinfo 时判为
  `sandbox_stale`，只提示重启应用，绝不 umount/bind；真正的层不同仍报 `skipped=layer`。
  可重建时若应用 ns 看不到 `/mnt/user/0/emulated`，当时会改用应用内
  `/storage/emulated/0/...` 作源（1.4.2 已删除该路径）。
- **安全边界**：宿主基准改用 `/proc/1/mountinfo` 的 `/mnt/user/0/emulated` 设备，
  逐进程比对应用 `/storage/emulated` 设备，分叉直接判 stale；`.sandbox_seen` 记录 `pkg|boot|ns|SB`，换 boot 后旧证据
  不再作为重建资格；重建子目录前先做层判定，别层挂载绝不 umount；共享目录源不可见时
  回滚刚 bind 的沙箱，不留下空沙箱。dry-run 不写任何状态文件。
- **配套**：新增 `tools/sandbox.test.sh`；`action.sh` / WebUI 增加沙箱丢失/僵死标签与体检文案；
  根因文档补充 vold 重挂 FUSE（MediaProvider 被杀）一节。

## 1.4.2 沙箱重建的安全边界与可观测性

- **回滚不叠父根**：只有沙箱 `umount` 确实卸干净才恢复被临时卸下的普通 FUSE 根；卸不干净时
  保留现状并报 `skipped=rollback`，不再把父根叠在残留沙箱上（避免应用看到整块存储）。
  回滚失败/原根恢复失败归为 `sandbox_stale`，不再混报可重试的 `sandbox_gone`。
  目标被别的挂载层占用时报 `sandbox_skip`（需重启应用），不再每 180 秒无效重试。
- **子进程**：`ps args` 为 `pkg:push` 时按基础包名 `pkg` 查配置、身份和 seen；
  `checked` 只统计配置里真实启用的进程；同包不同 namespace 分别处理。
- **dry-run 只读**：`-n` 不再清理/改写已有 `.sandbox_seen`（旧格式与空 ns 行只在非 `-n`
  持锁运行中清理）；沙箱退避键改用 `@sandbox`，避免和名为 sandbox 的自定义共享目录撞键。
- **日志去重**：同一份沙箱报告连续多轮只记一次日志，不再每轮刷重复行。
- **主扫描校验挂载栈**：`/storage/emulated/0` 必须“栈顶是本包沙箱且只有一层”才算健康；
  叠层/被其他层盖住时按 `rollback` / `sandbox_stale` 上报并提示重启应用，残留非本包沙箱
  不再登记为健康证据（K）。
- **失败退避**：复用 `.repairs` 的 failed 行做每包退避（180 秒，key 含 FUSE 设备号、boot、
  namespace），dev/boot/ns 任一变化立即失效；重建沙箱与 `repair_one` 的
  `source`/`source_ns`/`bindfail` 都不再每轮重试，RESULT 带 `retry=N`。
- **普通根 fail-closed**：没有本 boot、同 namespace 的 seen 证据时，普通 FUSE 根
  （root=`/` 或 `/0`）一律不卸不 bind，报 `sandbox_skip`（与可重试的 `sandbox_gone` 区分）；
  目标没有挂载（n=0）时仍可凭“源存在+属主匹配”重建。同 boot 异 namespace 回落同一条兜底规则，
  只有目标 n=0 才动手；本 boot 有任意 namespace 的行（或完全没有历史记录）即可回落，只有该包
  只剩旧 boot 行时才拒绝。
- **删除应用视图回退（ALT）**：应用 ns 看不到 `/mnt` 时直接失败，不再拿应用内
  `/storage/emulated/0/...` 当源；`sb_to_alt`/`sp_alt` 及相关用例一并移除。
- **状态与文案**：`status.json` 增加 `sandbox_rollback`/`sandbox_skip`，WebUI 主状态卡/banner、
  「操作」按钮直接显示这四项沙箱状态（最近一轮 fix 报错时标注为上次记录）。
- **action 健壮性**：体检加 `timeout 40`；拿不到 `RESULT` 行（空输出/前缀不对/超时/被 OOM）
  报“执行失败（无结果行）”，不再显示“没有需要修复”；fix 建锁失败改报 `error=datadir`。
- **发布**：用同一构建产物发布并校验资产 sha256（v1.4.2 资产前 8 位 `0201d2a2`）。
- **版本**：`v1.4.2` / `versionCode 142`。

## 1.4.3 边界收口

- **按原 root 恢复回滚**：卸普通 FUSE 根前记下 `(设备号, root)`；恢复时 root=`/` 用
  `/storage/emulated`，root=`/0` 优先从 FUSE 层 `/0` 挂回、应用 namespace 看不到时退回
  self-bind；恢复后必须“一层、设备号等于原值、root 等于原值”才打印已挂回，否则报
  `rollback`/`stale`。其它 root 不卸也不恢复。
- **裁剪不误删在跑的临时文件**：`--trim-only` 只清 PID 已退出或超过 30 分钟的
  `.si-out.dry.*` / `.si-conf.*` / `.si-parsed.*` / `.conf.cache.tmp.*`，活 PID 的新文件保留。
- **锚点目录缺失上报**：主扫描与重建循环里 `-d` 失败不再静默跳过，报
  `skipped=target_missing`、计入 `broken`，日志写出缺失的路径。
- **本次修复跟随当前轮**：守护每轮成功扫描都把 `last_fixed` 更新为本轮 `fixed`（0 也归零），
  累计值仍放在 `total_fixed`。
- **退避与 glob**：`.repairs` 的退避改看 `/proc/uptime` 单调时间，系统时间跳变不影响；
  旧格式（只写墙钟）的失败行按无退避处理，`retry=` 仍是剩余秒数。重建沙箱遍历
  `rb_allow` 时关闭 glob 展开，自定义目录名里的 `*` 按字面量补挂。
- **PID/ns 时点校验**：扫描时记录 pid 的 starttime（`/proc/<pid>/stat` 第 22 字段）、uid 与
  mount namespace，bind/umount 前重读比对，不一致报 `skipped=pid_changed` 且不碰挂载；
  扫描与动手之间的极短窗口保留在文档里说明。
- **版本**：`v1.4.3` / `versionCode 143`。

## 1.5.0 Android 17 应用列表可选补丁

- **问题**：Android 17（SDK 37）上 SI 8.8.1 r3684（server-v355）的应用列表为空，
  根因是 AIDL 返回类型 `PackageInfoList` 变更；替换 `server-v355.dex` 后列表恢复。
- **补丁脚本**：新增 `scripts/si-patch.sh`（`check` / `apply` / `restore` / `status`）。
  只替换 `/data/adb/storage-isolation/bin/server-v355.dex`，不碰 `main.dex`、
  不改 SI 配置、不动 SI 的其它文件，也不自动重启 SI。
- **安全边界**：`apply` 在 SDK 37、路径存在、SI versionName 前缀匹配且哈希为原版时执行；
  先备份原版（600），再复制到目标目录里的临时文件，`chown root:root`、`chmod 600`、
  校验 sha256 后原子替换；替换后再次校验目标 sha256，不符就用备份覆盖回去并报错。
  `unknown` 哈希拒绝操作，`patched` 重复执行是 no-op；锁防并发，持锁后会重新读状态。
- **恢复**：`restore` 从新到旧扫描备份，选第一份哈希为原版的；最新备份坏了会跳过。
  当前是 `unknown` 但存在有效原版备份时，加 `--force`（WebUI 为「强制恢复」）显式覆盖；
  恢复前会保存当前目标副本，失败时用副本回滚。
- **补丁资产**：`assets/server-v355.dex`；1.5.0 使用当时的补丁 dex，1.5.1 起改为自建 dex。
  构建时校验 sha256，zip 自检再校验一次，保持可复现。
- **界面**：WebUI 增加「Android 17 应用列表修复」卡片；首次检测到 `original` 时提示
  「应用补丁 / 暂不」，写 `.patch_prompted` 防重复，手动入口保留。应用、恢复、强制恢复
  都需二次确认，确认框显示目标 SI 版本和适用范围；`unknown` 且有有效备份时提供
  「强制恢复」；读取失败不隐藏卡片。结果回显并提示重开 SI；`action.sh` 增加一行补丁状态，
  不自动应用。
- **卸载**：卸载前若当前是补丁版，先尝试恢复原版；失败时保留数据目录（含备份）并打印路径，
  不再直接 `rm -rf` 唯一备份。
- **发布**：`v1.5.0` / `versionCode 150`，`update.json` 同步到 lukka-hub；管理器更新日志
  指向 `CHANGELOG.md`，只展示 1.5.0 的内容。
- **测试**：新增 `tools/patch.test.sh`，覆盖 SDK 不符、无 SI、版本门禁、原版应用、已应用
  no-op、unknown 拒绝、资产缺失/哈希不对、备份创建哈希、复制失败与替换后校验回滚、
  chown、umask 022 下 600、最新备份坏/旧备份有效、备份全坏、unknown 强制恢复、
  restore 当前副本回滚、无备份、持锁后重查、并发锁、卸载恢复/失败保留，以及 WebUI/action
  接线。

## 1.5.1 自建补丁 dex

- **鸣谢**：酷安用户「无所事事」提供了 Android 17 下 SI「无法读取应用列表」的解决思路。
- **自建 dex**：对官方 SI v355 的 `server-v355.dex` 自行反编译重打，不再使用 1.5.0 的补丁 dex；
  新文件 325,984 B，sha256 `7a941f35ee893f187f4b1c59995b43af0a1f9c12d3988dda0ea519d324c82bbe`。
- **反编译改动**：只改 4 条指令：
  1. `IPackageManager.getInstalledPackages(JI)` 返回类型 `ParceledListSlice` → `PackageInfoList`；
  2. `IPackageManager.getInstalledPackages(II)` 返回类型同上；
  3. 第一处 `ParceledListSlice.getList()` → `PackageInfoList.getList()`；
  4. 第二处 `ParceledListSlice.getList()` → `PackageInfoList.getList()`。
- **结构**：其余 386 类、1635 方法（1634 个方法体完全一致）、806 字段不变；新增字符串只有
  `Landroid/content/pm/PackageInfoList;`。
- **体积**：重打包时剥离了调试信息（不影响运行逻辑，只影响崩溃堆栈行号）；
  325,984 B，与原版 331,520 B 接近。
- **版本**：`v1.5.1` / `versionCode 151`；`CHANGELOG.md` 只展示 1.5.1。

## 1.5.2 SI server 自动重启与分级显示

- **自动重启 SI server**：apply/restore 成功后扫描 `/proc/*/maps`，只结束映射
  `server-v355.dex` 的进程（先 TERM 再 KILL），不杀 daemon/app；最多等 5 秒确认新进程
  出现并映射同一 dex。成功/未运行/失败分别写 `SERVER-RESTART ok/skip/fail` 日志；
  失败不回滚已写入的 dex，只提示重开 SI 或重启手机。
- **面板分级**：先只读 `getprop ro.build.version.sdk`，SDK 不是 37 时整张卡片隐藏且不请求
  `si-patch.sh check`；未装 SI（no-si）隐藏。SDK 37 但 `SI_MATCH=0` 或 `STATE=unknown`
  时显示卡片、按钮置灰并提示“当前 SI 版本/哈希不在支持范围，未做任何修改”；有有效原版
  备份且当前不是原版时只保留「强制恢复」。只有匹配的 `original` 才启用应用，`patched` 才启用恢复；
  首次提示也只在 SDK 37 + 匹配时出现。
- **测试**：新增 fake `/proc` + stub kill 的 server 重启成功/跳过/失败三条路径；补 SDK 14/15
  隐藏、版本不匹配置灰、unknown + 有效备份只留强制恢复的静态断言。
- **版本**：`v1.5.2` / `versionCode 152`；`CHANGELOG.md` 只展示 1.5.2。

## 兼容与边界

- Android 13~17、Magisk/KernelSU、FUSE 存储；
- 13~16 按 AOSP/toybox 源码核对，17 实机验证；
- 仅主用户；工作资料/多用户不支持；不恢复已删除数据。
