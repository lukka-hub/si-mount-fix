# 根因分析：挂载丢失与 2.0 通用 dex 兼容层

## 现象

微信、相册等应用能看到缩略图，但按路径读原图/视频失败，提示「视频已被删除」
「图片发送失败」。同一文件在文件管理器里可见，重启应用偶尔恢复。

## SI 的挂载模型

Storage Isolation（`moe.shizuku.redirectstorage`）的增强模式会为每个被隔离应用
创建各自的 mount namespace，并在其中重新挂载存储：

```text
/storage/emulated/0
  → /data/media/0/Android/data/<pkg>/sdcard          （沙箱根）

/storage/emulated/0/DCIM
/storage/emulated/0/Pictures
/storage/emulated/0/Download
/storage/emulated/0/Android/data/<pkg>
  → /mnt/user/0/emulated/0/...                       （FUSE 共享层）
```

第一组是应用私有的沙箱，第二组才是用户真实文件。SI 在应用启动、进程重建、
配置变更或系统重挂时会重放这些 bind mount。两组都在 FUSE 这一层：进程退出时
整个 namespace 随进程销毁；FUSE 被重挂时两组挂载会一起失效。

只丢第二组时，namespace 里只剩沙箱根，而它是一个近乎空的目录。因此：

- `access()`/`stat()` 按路径读 DCIM 原文件失败；
- MediaStore 的缩略图由 MediaProvider 生成并缓存，仍能显示；
- 文件管理器/系统相册走自己的 namespace，所以文件看起来还在。

## 为什么补出来的挂载仍然不可读

早期版本从 `/data/media`（f2fs 裸盘）补挂，设备号是 `254:37`；正常应用的
共享目录在 FUSE 层，设备号是 `0:285` 一类。SELinux 不允许 `untrusted_app`
直接读裸盘，`stat` 返回 `EACCES`，所以「挂上了但微信仍报已删除」。

正确做法是：

1. 从应用自己的 `/proc/<pid>/mountinfo` 识别沙箱根
   `/<user>/Android/data/<pkg>/sdcard`，得到沙箱设备号；
2. 共享目录必须来自 **FUSE 层** `/mnt/user/0/emulated/0/...`；
3. bind 后校验目标挂载的设备号与沙箱一致、挂载条数为 1；不一致就拆掉回滚。

## 谁在拆挂载：MediaProvider → vold → FUSE 重挂

进程被杀不是唯一路径。在 ColorOS 这类后台管理更激进的 ROM 上，更常见的是
应用进程根本没退出，挂载却整棵没了。真机（OnePlus PJZ110 / ColorOS V17.0.0 /
Android 17）实测的链路是：

```text
MediaProvider（com.android.providers.media.module，FUSE 守护进程）被杀
        │  ColorOS 后台管理：system_server 的 OsenseKillAction、
        │  内核侧 Hans 冻结、Athena 等
        ▼
vold（实测 pid 1222）的 binder 线程执行 umount("/mnt/user/0/emulated")
        │  连同 /mnt/user/0/emulated/999，随后重新挂载用户存储
        ▼
FUSE 设备号变化：0:235 → 0:286
        ▼
应用 namespace 里以旧 FUSE 为 master 的挂载整棵被摘除
```

实测：kill MediaProvider 前微信有 6 条共享目录挂载，kill 后 6 秒变成 0 条，
连 `/storage/emulated/0` 的沙箱挂载也一起消失；跟踪日志里
`binder:1222_4 ... umount name="/mnt/user/0/emulated"` 连续出现 9 次。
MediaProvider 的 `oom_score_adj` 是 -700，仍然会被杀。

这时应用进程还活着，但 namespace 里只剩宿主的 FUSE 挂载，`/storage/emulated/0`
不再是沙箱：应用看到真实存储，隔离失效，按路径读文件失败，表现为
「视频已被删除」「图片发送失败」。

### 为什么是整棵

应用 namespace 里的沙箱（`/storage/emulated/0`，mountinfo 的 root 是
`/0/Android/data/<pkg>/sdcard`）和所有共享目录（DCIM / Documents / Download /
Music / Movies / Pictures）、`Android/{data,media,obb}/<pkg>`，都是这棵 FUSE
挂载树里的 **slave**：`/proc/<pid>/mountinfo` 里带 `master:86`，只接收 86 号
peer group（传播组）的事件，自己的卸载不会反向传出去。

vold 在传播树上游把 FUSE 挂载卸载再重挂，卸载事件沿传播链下发到每个 slave 副本，
应用里的沙箱和共享目录被一起摘掉；重挂后的设备号从 `0:235` 变成 `0:286`，
说明这是新的挂载，旧的 bind 副本不会自己回来。结果不是某一条挂载失效，
而是整棵一起消失。

### 为什么旧版模块看不见

旧版靠沙箱挂载识别应用：从 `/proc/<pid>/mountinfo` 里找
`/<user>/Android/data/<pkg>/sdcard`，找不到就把这个进程跳过。FUSE 重挂后沙箱
本身也没了，于是 `checked` 下降、`broken=0`，看起来一切正常，实际一个都没修。

沙箱既是修复目标，也是识别锚点；锚点被一起摘走，旧版就失去了观测点。

### 与「进程被杀」的区别

- **进程被杀**：namespace 随进程销毁，沙箱和共享目录一起消失，没有 umount 事件；
  应用重启、SI 重建 namespace 后通常恢复。模块面对的是“进程还在、目录缺失”。
- **FUSE 重挂**：进程还在，挂载被上游整棵摘掉；trace 里能看到 vold 发出的 umount；
  应用重启会触发 SI 重建，但 MediaProvider 再被杀一次就会复发。

### 怎么现场观察

**看谁在 umount。** 在应用报错期间，给 `__arm64_sys_umount` 挂 kprobe，打印第一个
参数指向的字符串（tracefs 也可能在 `/sys/kernel/debug/tracing`）：

```sh
cd /sys/kernel/tracing
echo 'p:si_umount __arm64_sys_umount name=+0(+0($arg1)):ustring' >> kprobe_events
echo 1 > events/kprobes/si_umount/enable
echo 1 > tracing_on
cat trace_pipe
# binder:1222_4 ... umount name="/mnt/user/0/emulated"
```

重点看 name 为 `/mnt/user/0/emulated` 的行。排查完删掉探针：
`echo '-:si_umount' >> kprobe_events`。

**对比设备号。** 重挂前后分别读宿主和应用的挂载表：

```sh
grep ' /mnt/user/0/emulated ' /proc/1/mountinfo
grep ' /storage/emulated/0 ' /proc/<pid>/mountinfo
```

设备号在第三列，会从 `0:235` 变成 `0:286`；具体数值随设备和挂载次序变化。

**看传播关系。** `/proc/<pid>/mountinfo` 里的 `master:86` 表示这个挂载是 86 号
peer group 的 slave，只接收上游传播。本例宿主侧的 FUSE 挂载和应用里的沙箱、
共享目录都带这一项；上游一重挂，这些 slave 副本就没了。

### 修复边界（当前实现）

沙箱丢了也要能识别，所以模块在状态目录记一份 `.sandbox_seen`：哪些包曾经有过沙箱。扫描时
如果授权包在运行、却找不到沙箱挂载：先把沙箱 bind 回 `/storage/emulated/0`，再复用共享目录
修复逻辑从 FUSE 层补 DCIM、Download 等目录；重建失败（bind 失败或校验不通过）只报
`skipped=sandbox_gone`，不杀进程，不动其它挂载。

主扫描只在 `/storage/emulated/0` 栈顶是本包沙箱、且只有一层时才认为健康：叠层报 `rollback`，
栈顶被别的层盖住报 `sandbox_stale`，都不登记 `.sandbox_seen`，提示重启应用。没有本 boot、
同 namespace 的 `.sandbox_seen` 证据时，普通 FUSE 根（root=`/` 或 `/0`）不卸不 bind，报
`sandbox_skip`；目标被别的挂载层占用（例如残留的 f2fs bind）同样 `sandbox_skip`，不写失败行，
也不进入 180 秒重试。沙箱 umount 没卸干净、回滚失败或原 FUSE 根恢复失败时按 `rollback`/
`sandbox_stale` 上报并保留现状，不把父根叠在残留沙箱上，也不谎报可重试的 `sandbox_gone`。

重建沙箱和 `repair_one` 共用 `.repairs` 的失败退避：同包同目标 180 秒内不重试，key 含 FUSE
设备号、boot 和 namespace，任一变化立即失效，`RESULT` 带 `retry=`。进程匹配按 `ps args` 的
基础包名，`pkg:push` 这类子进程同样按基础包名查配置和身份，并按所在 namespace 与主进程分别
处理。应用视图回退（ALT）已删除：应用 ns 看不到 `/mnt` 时直接失败，避免在源不可见时静默
禁用预检。

### 不是 ColorOS 专有

这条链路是 AOSP 的机制：vold 在 FUSE 守护进程死亡后重挂用户存储。ColorOS 的差别
只在“MediaProvider 被杀的频率”——Osense/Hans 更激进，所以更容易触发；其它 ROM
在内存压力、清理后台时同样会发生。Android 11+（FUSE / scoped storage）都是这个
架构，13+ 之后后台冻结更普遍，体感上更频繁。

> 链路与数字来自 OnePlus PJZ110 / ColorOS V17.0.0 / Android 17 实测；
> 其它 ROM 未逐一验证，机制相同、触发频率不同。

## 为什么用事件驱动

丢失发生在应用 namespace 内的 mount/umount，轮询只能事后发现。模块用
kprobe 挂 `path_mount`/`path_umount`，读 tracefs 的 `trace_pipe`：

- 事件到达后合并 1 秒内的后续事件，再扫描一次；
- 只读取 `configuration.json` 授权包名的候选进程，避免全系统扫描；
- tracefs/kprobe 受 SELinux 或 OEM 内核限制时，自动降级为轮询；
- 启动时在私有 namespace 做一次 mount/umount 自检，确认事件真的能到达。

## 保护边界

- **fail-closed**：配置读不到、FUSE 未就绪、身份/层不一致时不动任何挂载；
- **FUSE defer**：开机未解锁/FUSE 未就绪时返回 `defer=fuse`，守护退避重试，
  超时才报 `fuse_missing`，不会把错误目录挂进应用；
- **churn 熔断**：同一目标反复被拆时暂停并重试，避免和 SI 抢挂载；
- **假活只提示**：kprobe 在响但 `trace_pipe` 读不到时标记 `blind`，不自动重建；
- 只处理主用户（user 0）和 FUSE 存储；不恢复已删除文件，不修改 SI 配置。

## A17 应用列表：PackageInfoList 与 server fallback

Android 17 的 `IPackageManager.getInstalledPackages(long, int)` 返回类型从
`ParceledListSlice` 改为 `PackageInfoList`；DEX 方法引用把返回类型算进签名，按旧签名编译的
调用点在 A17 上会抛 `NoSuchMethodError`/`NoClassDefFoundError`。SI 在列表链路上有 catchall，
异常被吞掉后返回空列表，界面就是 SI 应用列表为空。

SI 的 `server-v355.dex` 是独立 root server 进程加载的。原版 `k` 类里的列表方法有两个
`getInstalledPackages` invoke（文件偏移 `0x01c38c`、`0x01c3a8`）仍按旧签名；A17 上第一次调用
失败后，catchall 返回空列表，再走内置 fallback：

```text
ServiceManager.getService("activity")
  → transact(0x5f5f5352, action=7)
  → main.dex 的 a1 action 7 读取 SI 自己的 ParcelableListSlice
```

所以 main.dex 的 a1 修好（能解析 A17 返回、把结果写回 SI 自协议）后，列表即可恢复。2.0 的 a1
action 7 调用 a2：`a2.e` 用反射取 `IPackageManager.getInstalledPackages(long, int)`，`a2.f` 判断
返回对象，`instanceof List` 直接用，否则反射 `getClass().getMethod("getList")`，空/异常/非 List
回 `Collections.emptyList()`。a1 的 action 8 保留原语义，不在 SI 的列表 fallback 链上。

`server-v355` 不进入 2.0 单 dex 交付：SI daemon 每次启动（含开机）会把内嵌原版写回 server dex，
替换不持久；A17-only 的 03（325,984 B / `7a941f35…`）直接引用 `PackageInfoList`，不是 A15–A17
通用资产；没有归档真机证据。03 仅作为 A17 可选兜底/诊断件，不在 `assets/`，没有安装/恢复脚本，
不写“已集成”。

## MediaProvider 导出规则、applyBatch、DownloadProvider

**导出规则**：SI 通过 hook `ServiceManager` 返回值把 `IActivityManager` 换成自己的代理，应用
启动时 `ActivityThread` 取到代理，`publishContentProviders` 才会把 MediaProvider 包成带 q0 规则
的 wrapper。A17 的服务查找路径变为 `sCache → rawGetService → getService2`，返回
`android.os.Service` / `ServiceWithMetadata`；原版 SI 的 `u0.invoke` 只处理 `getService`/
`addService`，`getService2` 落入默认分支，ActivityThread 缓存到裸 `IActivityManager`，wrapper
不执行，`relative_path` 从不改写。A15 release 走旧 `getService`；A15 QPR1/QPR2、A16/A17 的
union 形态不同。2.0 的 `u0` 覆盖 `getService`/`checkService`/`getService2`/`checkService2`，只对
`activity`/`vold` 且返回非 `IBinder` 时进入 `u2` 反射适配，同一 binder 返回原对象，其它服务
原样返回。

**applyBatch**：q0 的改写挂在单条 insert/update/bulkInsert 上；provider wrapper 的事务白名单按
“已实现的方法”生成，applyBatch 不在其中。`ContentProviderNative` 的
`APPLY_BATCH_TRANSACTION = FIRST_CALL_TRANSACTION + 19`（A15–A17 均为 20），整个批次原样透传：
批量 insert 不迁移，批量 update 能把已导出文件移回源目录。2.0 的 `r.applyBatch` 按 provider 分派，
`x3` 逐 op 反射取 URI 和 `mValues` 复用单条规则，结果数组/下标/back-reference 对齐；无法安全
改写时整批 `SecurityException`，非隔离 uid 早退 forward。

**DownloadProvider**：独立 provider，有自己的 `hint` 和路径解析，不经过 MediaProvider 的 q0。
原版 `v` 的 insert/bulkInsert 已按规则改写 hint，但 applyBatch 不拦、`v.f` 没有 target 幂等判断、
`v.d` 只处理 `/my_downloads` 集合。2.0 的 `v.f` 做 canonical 化、拒绝 `..`、已在 target 内幂等；
`v.d` 对 `/my_downloads` 和 `/my_downloads/<id>` 前缀匹配；`r.applyBatch` 对 downloads 的 insert
逐 op 调 `v.f`，update/delete 原样。A17 `local_uri` placeholder、delete 只删数据库行、MTP 行为
属平台语义，不改。

## 通用 dex 的设计取舍

- **一份 dex**：A17 的返回类型与 A15/A16 不同，直接引用新类型会让旧系统在类加载/调用时失败；
  按版本拆又要求用户选文件。2.0 只接受官方 90,740 B / `a407674b…` 作为 base，整份替换；a1/a2
  运行时判断返回对象，u0/u2 用反射探测 `Service`/`ServiceWithMetadata`，缺类/缺方法回原路径或
  空跑。
- **窄 hook**：全局包装方案（每个 getService2/checkService2 都重建 union）会让非目标服务换
  对象、在启动期放大反射/分配，并直接引用新系统类；2.0 只处理 activity/vold、同 binder 返回
  原对象，非目标 getService2 只做少量 `equals`。
- **失败回滚**：所有新分支的空值、异常、结构不符回原路径或 fail-closed；a1 不做逐包
  `getPackageInfo` 的 N+1；`r.applyBatch` 的 uid 优先取 `Binder.getCallingUid()`，attr 只在
  拿不到时兜底。

## 证据与边界

- **已验证（模拟器/构建）**：115 个类；baksmali→assemble 往返 byte-identical；禁止直接引用
  `PackageInfoList`/`android.os.Service`/`ServiceWithMetadata` 的扫描为 0；A15/A17 模拟器
  `dex2oat` 0 个 verification error、115/115 类加载，harness 58/58；构建可复现 92,856 B /
  `2f3ca326…`。
- **未验证**：A16、A15 QPR1/QPR2 无真镜像，相关 Service union 只有 AOSP 静态核对 + harness
  桩；2.0 dex 没有真机 E2E，真实 `IPackageManager`/PMS、真实 MediaProvider/DownloadProvider、
  `applyBatch` 的真实 `onTransact`、`q0.b` 跨 uid update、Download E2E 都未跑；真机冷启动未做
  A/B；“≤ 原版 +10%”是目标不是结果；hidden API/OEM ROM 差异未逐一验证。
- **不要写成“全量验收通过”**：可以说“A15/A17 模拟器 ART + 58/58 harness 通过，A15–A17 共用
  一份 dex”；A16/QPR/真机/冷启动仍是升级后需要用户自行确认的边界。
- **挂载侧**：A17 真机（OnePlus PJZ110 / ColorOS V17.0.0）有 MediaProvider 被杀、vold 重挂
  FUSE 的现场证据；Android 13–16 只做了 AOSP/toybox 源码核对。2.0 本次未重新做挂载真机回归。

## 调用链与文件位置（main.dex）

| 类/方法 | 作用 |
|---|---|
| `Lrikka/storageisolation/a1;` action 7/8 | SI 应用列表动作；action 7 是 server fallback 实际走的链路 |
| `Lrikka/storageisolation/a2;` `e` / `f` | 反射 `getInstalledPackages`，把 `List`/`getList()` 两种返回适配成列表 |
| `Lrikka/storageisolation/u0;` `invoke` | 处理 `getService` / `checkService` / `getService2` / `checkService2` / `addService` |
| `Lrikka/storageisolation/u2;` `a` | 反射重建 `Service` / `ServiceWithMetadata` union；同 binder 返回原对象 |
| `Lrikka/storageisolation/q0;` `g` / `b` / `c` | observer 规则匹配、单条 update 门、insert 规则 |
| `Lrikka/storageisolation/r;` `applyBatch` / `c` | 批量入口分派、事务码注册 |
| `Lrikka/storageisolation/x3;` `a` / `media` | 逐 op 反射改写（Media/Download），结果数组对齐 |
| `Lrikka/storageisolation/v;` `f` / `d` | Download `hint` 改写、`/my_downloads` 前缀匹配 |
| `Lrikka/storageisolation/h1;` | 通过真实 `ContentProviderProxy` 计算并注册 applyBatch 事务码（20） |

核对命令（需要 baksmali/dexdump）：

```sh
sha256sum assets/main.dex
# 2f3ca3263225d2577ab132e16dcc7273a61a80feea232b2f32e0100f6b3c8a22
java -cp "<smali 依赖>" org.jf.baksmali.Main disassemble -o /tmp/si-main assets/main.dex
dexdump -d assets/main.dex | grep -n -E 'a1;|u0;|q0;|r;|v;|x3;'
```
