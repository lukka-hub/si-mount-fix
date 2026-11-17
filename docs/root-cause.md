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
配置变更或系统重挂时会重放这些 bind mount；其中第二组在某些时机丢失，应用
的 namespace 里就只剩沙箱根。

沙箱根本身是一个近乎空的目录，因此：

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

## FUSE 重挂（MediaProvider 被杀）

ColorOS 等 ROM 的进程管理会杀掉 `com.android.providers.media.module`（MediaProvider）。
它退出后 `vold` 会先 `umount /mnt/user/0/emulated`，再重新挂载 FUSE 存储，FUSE 的
设备号随之变化（真机实测 `0:235` → `0:286`）。应用 namespace 里来自这块 FUSE 的挂载
都是它的 slave（mountinfo 里的 `master:86`），master 被拆后内核会把这些 slave 一起摘掉：

- 沙箱根 `/storage/emulated/0`（source `/<user>/Android/data/<pkg>/sdcard`）消失；
- 共享目录（DCIM/Documents/Download/Music/Movies/Pictures）消失；
- `Android/{data,media,obb}/<pkg>` 也消失。

应用不会立刻崩溃，但按路径读文件时看到的是“无沙箱”的真实存储，于是视频/图片突然
提示“已被删除”；缩略图来自 MediaStore 缓存，可能仍然可见，更容易误判。

v1.4.1 起，模块把“曾经识别到合法沙箱”的包记录在 `.sandbox_seen`。这类包的进程还在、
年龄达标、但当前 namespace 里没有沙箱挂载时，模块会：

1. 校验沙箱源存在、属主等于进程 uid、应用 namespace 里能看到源、目标目录存在，
   且目标当前不是沙箱；
2. 把 `<host FUSE>/<user>/Android/data/<pkg>/sdcard` bind 回 `/storage/emulated/0`；
3. 校验目标设备号是当前 FUSE 设备号、挂载条数为 1、source 指向该包沙箱；任一条
   不满足立即 `umount -l` 回滚；
4. 复用正常修复路径补回 allow 目录与 `Android/{data,media,obb}/<pkg>`。

全程只在应用自己的 namespace 里 bind，不杀进程、不改 SI 配置。重建失败（源目录已被清理、
目标被别的挂载占用、校验不过等）报 `skipped=sandbox_gone`，下一轮继续尝试。

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
