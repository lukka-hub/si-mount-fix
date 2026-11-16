# 演化过程（1.0 → 1.3.9）

> 说明：1.0~1.3.1 的提交是根据早期文档与发布产物回溯的说明，原始源码没有保留；
> 1.3.2 起是真实代码提交。1.3.3 未形成独立发布 tag，1.3.4 接续。

## 1.0 第一代：纯脚本补挂载

- 发现 SI 在应用 mount namespace 里只保留沙箱 bind；
- `fix-si-mounts.sh` 扫描 `/proc/*/mountinfo`，按需补齐共享目录。

## 1.1 修正来源层：f2fs 裸盘 → FUSE

- 补出来的挂载设备号是 `254:37`（f2fs），SELinux 不允许 untrusted_app 读；
- 来源改为 `/mnt/user/0/emulated/0/...`；
- 新增层校验：目标设备号必须等于沙箱设备号，否则拆掉重挂。

## 1.2 事件驱动 + 扫描提速

- `si-mount-eventd.sh`：kprobe(path_mount/path_umount) + 独立 trace 实例 +
  `trace_pipe` 阻塞读；
- 内核 filter 排除 mount/umount/nsenter/magiskd，防止自触发；
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

## 兼容与边界

- Android 13~17、Magisk/KernelSU、FUSE 存储；
- 13~16 按 AOSP/toybox 源码核对，17 实机验证；
- 仅主用户；工作资料/多用户不支持；不恢复已删除数据。
