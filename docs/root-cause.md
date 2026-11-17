# 根因分析：Storage Isolation 为什么会丢共享目录挂载

## 现象

微信、相册等应用能看到缩略图，但按路径读原图/视频失败，提示「视频已被删除」
「图片发送失败」。同一文件在文件管理器里可见，重启应用偶尔恢复。

## SI 的挂载模型

Storage Isolation（`moe.shizuku.redirectstorage`）的增强模式会为每个被隔离应用
创建独立的 mount namespace，并在其中重新挂载存储：

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
grep ' /mnt/user/0/emulated ' /proc/self/mountinfo
grep ' /storage/emulated/0 ' /proc/<pid>/mountinfo
```

设备号在第三列，会从 `0:235` 变成 `0:286`；具体数值随设备和挂载次序变化。

**看传播关系。** `/proc/<pid>/mountinfo` 里的 `master:86` 表示这个挂载是 86 号
peer group 的 slave，只接收上游传播。本例宿主侧的 FUSE 挂载和应用里的沙箱、
共享目录都带这一项；上游一重挂，这些 slave 副本就没了。

### 1.4.1 的处理

沙箱没了也要能识别，所以模块在状态目录记一份 `.sandbox_seen`：哪些包曾经有过
沙箱。扫描时如果授权包在运行、却找不到沙箱挂载：

1. 先把沙箱挂回去：bind `/mnt/user/0/emulated/0/Android/data/<pkg>/sdcard`
   到 `/storage/emulated/0`；
2. 再复用原来的共享目录修复逻辑，从 FUSE 层补 DCIM、Download 等目录；
3. 重建失败（bind 失败或校验不通过）只报 `skipped=sandbox_gone`，不杀进程，
   不动其它挂载，下一次扫描再试。

沙箱恢复后隔离重新生效，识别锚点也回来了，后续修复才有对象。

两种故障态要分开看：

- **可重建（`sandbox_gone`）**：应用 namespace 里已经没有沙箱挂载，但还能看到宿主
  重挂后的新 FUSE（`/mnt/user/0/emulated` 或 `/storage/emulated` 的设备号等于宿主）。
  模块按上面的步骤重新 bind 沙箱，再补共享目录；应用 ns 里没有
  `/mnt/user/0/emulated` 时，回退用应用自己的 `/storage/emulated/0/...` 视图作源。
- **僵死（`sandbox_stale`）**：应用 namespace 里的沙箱还是旧设备号（实测 `0:286`），
  宿主已经是新设备号（`0:318`）；应用内读 `/storage/emulated/0/...` 报
  `Transport endpoint is not connected`。旧 FUSE 会话已经不存在，跨 namespace bind
  会 `EINVAL`，卸掉旧挂载也拿不到新 FUSE；模块只能报 `skipped=sandbox_stale`，
  不碰挂载，需要重启该应用让 SI 重建 namespace。扫描时只有“沙箱本身是 FUSE 且
  设备号在宿主 `/proc/self/mountinfo` 里查不到”才会判僵死，真正挂在别的层的沙箱
  仍报 `skipped=layer`。

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
