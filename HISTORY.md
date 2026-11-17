# 演化过程（1.0 → 1.4.1）

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
  补了回归用例；`uninstall.sh` 改为按 cmdline 精确匹配，不再宽泛 `pkill -f`。
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
  可重建时若应用 ns 看不到 `/mnt/user/0/emulated`，源回退到应用视图
  `/storage/emulated/0/...`。
- **配套**：新增 `tools/sandbox.test.sh`；`action.sh` / WebUI 增加沙箱丢失/僵死标签与体检文案；
  根因文档补充 vold 重挂 FUSE（MediaProvider 被杀）一节。

## 兼容与边界

- Android 13~17、Magisk/KernelSU、FUSE 存储；
- 13~16 按 AOSP/toybox 源码核对，17 实机验证；
- 仅主用户；工作资料/多用户不支持；不恢复已删除数据。
