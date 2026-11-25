# 根因分析：挂载丢失与 main.dex 兼容层

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

## 为什么挂载会掉：MediaProvider → vold → FUSE

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

### 进程被杀、namespace 死亡与挂载失效的区别

- **进程被杀**：namespace 随进程销毁，沙箱和共享目录一起消失，没有 umount 事件；
  应用重启、SI 重建 namespace 后通常恢复。模块面对的是“进程还在、目录缺失”。
- **FUSE 重挂**：进程还在，挂载被上游整棵摘掉；trace 里能看到 vold 发出的 umount；
  应用重启会触发 SI 重建，但 MediaProvider 再被杀一次就会复发。
- **namespace 死亡**：不是挂载点单独消失，而是整个 `/proc/<pid>/ns/mnt` 消失，
  任何针对该进程的 mount 操作都无从下手；模块只能等进程重启后重新扫描。

### 为什么旧版看不见

旧版靠沙箱挂载识别应用：从 `/proc/<pid>/mountinfo` 里找
`/<user>/Android/data/<pkg>/sdcard`，找不到就把这个进程跳过。FUSE 重挂后沙箱
本身也没了，于是 `checked` 下降、`broken=0`，看起来一切正常，实际一个都没修。

沙箱既是修复目标，也是识别锚点；锚点被一起摘走，旧版就失去了观测点。

### 现场观察

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

## Android 15 / 16 / 17 为什么失效

三个版本共用一个根因模型：SI 的 `main.dex` 只覆盖旧的服务查找名和单条
provider 路径；FUSE 挂载丢失的问题与 SDK 无关，MediaProvider 导出、`applyBatch`、
DownloadProvider 的规则缺口也一直存在。差异在接口形态：

### Android 15（SDK 35）

- **应用列表可用**：`getInstalledPackages` 仍返回 `ParceledListSlice`，旧调用能解析，
  列表不是故障点。
- **MediaProvider 导出受影响**：wrapper 本身能挂上，但 accessible 目录、observer 的
  source→target 规则没有进入 insert/update；`relative_path` 越界没有拦住；
  只有 `_data` 的 update 没有 fail-closed。
- **applyBatch 受影响**：provider wrapper 的事务白名单里没有批量事务，批量
  insert/update 原样透传，已导出的文件可能被批量 update 移回源目录。
- **DownloadProvider 受影响**：hint 缺少规范化/`..` 拦截/target 幂等；
  `/my_downloads/<id>` 只按集合处理。
- **ServiceManager**：release 版本没有 `getService2`，只走 `getService`，wrapper 能
  激活；QPR1/QPR2 增加了 `getService2`，返回 `android.os.Service` 的 union 形态，
  原 `u0.invoke` 不认识这个方法名，走默认分支，ActivityThread 缓存到裸
  `IActivityManager`，wrapper 不再执行。A15 release 不能启用不存在的 `getService2`，
  否则会 `NoSuchMethodError`。

### Android 16（SDK 36）

- **应用列表可用**：仍返回 `ParceledListSlice`，旧路径能解析。
- **MediaProvider 导出、applyBatch、DownloadProvider**：与 A15 相同的规则缺口。
- **ServiceManager**：`getService2` 返回 `ServiceWithMetadata` 包装，
  `checkService` 返回 `IBinder`，`checkService2` 返回 `Service`。原 `u0` 只处理
  `getService`/`addService`，新方法名落入默认分支，provider wrapper 不执行；
  `ServiceWithMetadata` 是 A15 QPR2 / A16 起出现的类型，不能直接写进通用 dex。

### Android 17（SDK 37）

- **应用列表失效**：`IPackageManager.getInstalledPackages(long, int)` 的返回类型从
  `ParceledListSlice` 改为 `PackageInfoList`。DEX 方法引用把返回类型算进签名，
  按旧签名编译的调用点在 A17 上抛 `NoSuchMethodError`/`NoClassDefFoundError`，
  SI 的 catchall 吞掉异常后返回空列表，界面就是 SI 应用列表为空。
- **MediaProvider 导出、applyBatch、DownloadProvider**：与 A15/A16 相同的规则缺口。
- **ServiceManager**：`getService2`/`checkService2` 返回 `android.os.Service`，
  `checkService` 返回 `IBinder`。服务查找路径是 `sCache → rawGetService →
  getService2`，原 `u0` 不认识 `getService2`，ActivityThread 缓存到裸
  `IActivityManager`，wrapper 不执行，`relative_path` 从不改写。

通用 dex 不直接引用 `PackageInfoList`、`android.os.Service`、`ServiceWithMetadata`
这些只在单一版本存在的类型；a1/a2/u2 全部用反射或 `instanceof` 探测，缺类/缺方法
时回到原路径或空跑。

## 每类能力的根因与解决思路

### 应用列表（a1/a2）

根因是 A17 的返回类型变化和 SI 自己的 server fallback 链路。SI 的
`server-v355.dex` 由独立 root server 进程加载，原 `k` 类里的列表方法有两个
`getInstalledPackages` invoke（文件偏移 `0x01c38c`、`0x01c3a8`）仍按旧签名；
A17 上第一次调用失败后，catchall 返回空列表，再走内置 fallback：

```text
ServiceManager.getService("activity")
  → transact(0x5f5f5352, action=7)
  → main.dex 的 a1 action 7 读取 SI 自己的 ParcelableListSlice
```

解决思路：a1 action 7 调 a2；`a2.e` 用反射取
`IPackageManager.getInstalledPackages(long, int)`，`a2.f` 判断返回对象，
`instanceof List` 直接用，否则反射 `getClass().getMethod("getList")`，
空/异常/非 List 回 `Collections.emptyList()`。a1 action 8 保留原语义，不在 SI
的列表 fallback 链上。A15/A16 继续走旧 `ParceledListSlice`，不需要额外分支。

### MediaProvider 导出规则（q0.g）

根因是规则匹配顺序和改写范围不完整：provider wrapper 只在部分单条路径上执行，
accessible 目录被提前放行，observer 的 source→target 规则没有进入 insert/update；
`relative_path` 直接透传，带 `..` 或越界路径可以逃出沙箱；只有 `_data` 的 update
没有拒绝，等于允许调用方绕过 `relative_path` 指向任意已挂载文件。

解决思路：`q0.g` 先按 observer 的 source→target 规则匹配，再判断 accessible；
insert 和 update 都走同一套规则；`relative_path` 越界拒绝或改写到目标目录内；
只有 `_data` 而没有可校验 `relative_path` 的 update 直接 fail-closed。`q0.b`
保留单条 update 的门禁，跨 uid 的 update 也只按规则放行。

### applyBatch（r/x3）

本节只覆盖 **MediaProvider / DownloadProvider** 的 `applyBatch`；其他 provider 的批量事务和 `bulkInsert` 不在本 dex 的拦截范围，按原路径透传。根因是批量事务没有进入 provider wrapper 的白名单。`ContentProviderNative` 的
`APPLY_BATCH_TRANSACTION = FIRST_CALL_TRANSACTION + 19`（A15–A17 均为 20），
wrapper 按“已实现的方法”生成白名单时没有包含 applyBatch，整个批次原样透传：
批量 insert 不迁移，批量 update 能把已导出文件移回源目录。批次里的
back-reference（后续 op 引用前面 op 的结果）还会让逐 op 改写后的结果数组错位。

解决思路：`r.applyBatch` 按 provider 分派，`x3` 逐 op 反射取 URI 和 `mValues`，
复用单条规则改写；结果数组、下标、back-reference 按原顺序对齐。遇到无法安全
改写（back-reference、未知 provider、结构不符）时整批 `SecurityException`，
不静默放行；非隔离 uid 早退 forward。

### DownloadProvider（v.f/v.d）

根因是 DownloadProvider 是独立 provider，有自己的 `hint` 和路径解析，不经过
MediaProvider 的 q0。原 `v` 的 insert/bulkInsert 已按规则改写 hint，但 applyBatch
不拦、`v.f` 没有 target 幂等判断、`v.d` 只处理 `/my_downloads` 集合。

解决思路：`v.f` 做 canonical 化、拒绝 `..`、已经在 target 内时幂等返回；
`v.d` 对 `/my_downloads` 和 `/my_downloads/<id>` 前缀匹配；`r.applyBatch` 对
downloads 的 insert 逐 op 调 `v.f`，update/delete 原样保留。A17 `local_uri`
placeholder、delete 只删数据库行、MTP 行为属平台语义，不改。

### ServiceManager（u0/u2）

根因是 SI 通过 hook `ServiceManager` 返回值把 `IActivityManager` 换成自己的代理，
应用启动时 `ActivityThread` 取到代理，`publishContentProviders` 才会把
MediaProvider 包成带 q0 规则的 wrapper。原 `u0.invoke` 只处理 `getService`/
`addService`，各版本的新方法名和返回类型都落入默认分支：

- A15 release：没有 `getService2`；QPR1/QPR2 的 `getService2` 返回
  `android.os.Service` union。
- A16：`getService2` 返回 `ServiceWithMetadata`，`checkService` 返回 `IBinder`，
  `checkService2` 返回 `Service`。
- A17：`getService2`/`checkService2` 返回 `Service`，`checkService` 返回 `IBinder`。

解决思路：`u0` 覆盖 `getService`/`checkService`/`getService2`/`checkService2`/
`addService`；只对 `activity`/`vold` 且返回值不是 `IBinder` 时进入 `u2` 反射适配；
同一 binder 返回原对象；非目标服务原样返回。`u2` 先试
`getServiceWithMetadata`，失败再试 `getBinder`，类/方法缺失时回原路径。通用 dex
不直接引用这些 A15/A16/A17 才有的类型。

### 挂载事件（mount eventd）

根因是挂载丢失发生在应用 namespace 内的 mount/umount，轮询只能事后发现，
而且容易把“还没挂好”误判成“丢了”。模块用 kprobe 挂 `path_mount`/`path_umount`，
阻塞读 tracefs 的 `trace_pipe`：

- 事件到达后合并 1 秒内的后续事件再扫描，避免一次重挂触发多轮修复；
- 只读取 `configuration.json` 授权包名的候选进程，避免全系统扫描；
- 启动时在私有 namespace 真做一次 mount/umount 自检，确认两侧事件都能到达；
  只看 tracefs 文件是否存在会被只读 tracefs 或裁剪内核骗过；
- `path_mount`/`path_umount` 缺失时回退 `ksys_mount`/`do_mount`、
  `ksys_umount`/`do_umount`；
- tracefs 缺失、kprobe 注册失败、自检失败或事件通道被占用时自动降级轮询，
  原因写入 `status.json`；通道被占用则定期探测是否空闲；
- 每 60 秒采样 kprobe 命中、`read events` 增量和 `last_event`，连续两个周期
  异常才标记 `blind`，只提示重启，不擅自删除实例或 kprobe。

挂载修复本身还有一层根因：沙箱丢了也要能识别，所以模块在状态目录记
`.sandbox_seen`；扫描时如果授权包在运行、却找不到沙箱挂载，先把沙箱 bind 回
`/storage/emulated/0`，再复用共享目录修复逻辑从 FUSE 层补 DCIM、Download 等。
重建失败只报 `skipped=sandbox_gone`，不杀进程，不动其它挂载。

主扫描只在 `/storage/emulated/0` 栈顶是本包沙箱、且只有一层时才认为健康：叠层报
`rollback`，栈顶被别的层盖住报 `sandbox_stale`，都不登记 `.sandbox_seen`，提示
重启应用。没有本 boot、同 namespace 的 `.sandbox_seen` 证据时，普通 FUSE 根
（root=`/` 或 `/0`）不卸不 bind，报 `sandbox_skip`；目标被别的挂载层占用
（例如残留的 f2fs bind）同样 `sandbox_skip`，不写失败行，也不进入 180 秒重试。
沙箱 umount 没卸干净、回滚失败或原 FUSE 根恢复失败时按 `rollback`/
`sandbox_stale` 上报并保留现状，不把父根叠在残留沙箱上。

重建沙箱和 `repair_one` 共用 `.repairs` 的失败退避：同包同目标 180 秒内不重试，
key 含 FUSE 设备号、boot 和 namespace，任一变化立即失效，`RESULT` 带 `retry=`。
进程匹配按 `ps args` 的基础包名，`pkg:push` 这类子进程同样按基础包名查配置和身份，
并按所在 namespace 与主进程分别处理。

## 修复边界

- **fail-closed**：配置读不到、FUSE 未就绪、身份/层不一致、源目录在应用 ns
  不可见时不动任何挂载；宁可这轮不修，也不把错误目录挂进应用。
- **FUSE defer**：开机未解锁/FUSE 未就绪时返回 `defer=fuse`，守护按
  1/2/4/8/15/30 秒退避重试，超时才报 `fuse_missing`，不会把错误目录挂进应用。
- **PID/ns 再校验**：扫描时记下 starttime、uid 和 mount namespace，真正
  bind/umount 前再读一次，任一不一致就跳过（`skipped=pid_changed`）。
- **churn 熔断**：同一 `(包名, 目标)` 在 300 秒内被修复 3 次，或距上次成功修复
  不到 1 秒，就暂停该目标，10 分钟后只重试一次；重试仍失败则锁定 1 小时。
- **只处理主用户（user 0）和 FUSE 存储**；不恢复已删除文件，不修改 SI 配置，
  不跨 namespace 强拆，不能把“进程已死”当成可原地修复。
- **兼容层边界**：只替换 `zygisk-storage-isolation/main.dex`，不重启 SI server；
  不做全局 activity 代理，不做逐包 `getPackageInfo`，不支持多用户/工作资料；
  只覆盖 SDK 35/36/37，其它版本 `check` 报 `unsupported`、`apply` 拒绝。
- **server-v355 不进入单 dex 交付**：SI daemon 每次启动（含开机）会把内嵌原版
  写回 server dex，替换不持久；A17-only 的 03（325,984 B / `7a941f35…`）直接引用
  `PackageInfoList`，在 A15/A16 上类加载/调用会失败，不能作为通用资产；目前也没有
  归档真机证据。因此只交付 `main.dex`，server-v355 不进入 `assets/`。

## 证据

- **已验证（模拟器/构建）**：115 个类；baksmali→assemble 往返 byte-identical；
  禁止直接引用 `PackageInfoList`/`android.os.Service`/`ServiceWithMetadata` 的扫描为 0；
  A15/A17 模拟器 `dex2oat` 0 个 verification error、115/115 类加载，harness 58/58；
  构建可复现 99,840 B / `65d51f6f…`。
- **未验证**：A16、A15 QPR1/QPR2 无真镜像，相关 Service union 只有 AOSP 静态核对 +
  harness 桩；通用 dex 没有真机 E2E，真实 `IPackageManager`/PMS、真实
  MediaProvider/DownloadProvider、`applyBatch` 的真实 `onTransact`、`q0.b` 跨 uid
  update、Download E2E 都未跑；真机冷启动未做 A/B；hidden API/OEM ROM 差异未逐一
  验证。
- **挂载侧**：A17 真机（OnePlus PJZ110 / ColorOS V17.0.0）有 MediaProvider 被杀、
  vold 重挂 FUSE 的现场证据；Android 13–16 只做了 AOSP/toybox 源码核对，本次未重新
  做挂载真机回归。

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
# 5e342a662f9e553ee7ce4dd666cac3de46b2cb08f86d25d0f768e7df7e8d4b51
java -cp "<smali 依赖>" org.jf.baksmali.Main disassemble -o /tmp/si-main assets/main.dex
dexdump -d assets/main.dex | grep -n -E 'a1;|u0;|q0;|r;|v;|x3;'
```
