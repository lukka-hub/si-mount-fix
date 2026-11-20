# 实验性修复：`zn-zygisk-companion` 高 CPU

> 对应版本：v2.0.2 的「实验性功能」入口（默认关闭）。
> 作用对象：Zygisk 增强模块 `zygisk-storage-isolation` **v29.0.1 / versionCode 89**。
> 本文记录现象、根因、修复、验证与限制；日常使用说明见 [README](../README.md)。

## 1. 现象

部分设备上，`zn-zygisk-companion32` / `zn-zygisk-companion64` 在开机一段时间后
持续占用单核 90% 以上，且不会自己恢复。重启可暂时缓解，但过一段时间复发。

这些进程不是 Storage Isolation 应用的一部分，而是 **Zygisk 增强模块的原生 companion**：

- 它的 `.so` 自带 `zygisk_companion_entry` 入口；
- Zygisk 侧每来一次请求就起一个线程调用该入口；
- 只要入口不返回，这个线程就不会退出。

## 2. 根因

`zygisk-storage-isolation` v29.0.1 的 `zygisk_companion_entry` 里有一段**命令循环**：

1. 从传进来的 socket fd 读 4 字节握手；
2. 按命令处理（转发 dex fd、准备临时目录等）；
3. 回到步骤 1 继续读下一帧。

问题出在**读失败时的分支**：

- 该 fd 是 `AF_UNIX SOCK_DGRAM + O_NONBLOCK`（真机 `fdinfo` 为 `02004002`）；
- 没有数据时 `read()` 返回 `-1 / EAGAIN`；
- 代码只把 `== 0`（EOF）当作"结束"，`-1` 会走"回去重读"；
- 这个"回去重读"没有 `poll`、没有超时、没有退避、没有次数上限。

于是只要对端没有按它的预期发送握手，就会形成 **约 200 万次/秒的 `read()` 空转**，
单核打满且永不退出。Zygisk 每请求一个线程，泄漏会随使用时间累积。

> 补充：AF_UNIX DGRAM 下关闭对端**不会**产生 EOF，`read` 仍然是 `EAGAIN`，
> 所以"等对端断开就好了"不成立。

## 3. 为什么只有 v29 会中招

同一入口在更早的 28.x 里**根本不读这个 socket**（只写），所以不存在该循环。
缺陷是 v29 线引入的，与 Storage Isolation 应用、`main.dex`、挂载修复都无关。

## 4. 为什么 2025 年集中出现

缺陷在 2023 年就随 v29 发布，但直到 Zygisk 侧真正开始调用 companion 才可能触发：

| 时间 | 事件 |
|---|---|
| 2023-08 | 增强模块 v29 发布，埋下"握手读" |
| 2024-09 | Zygisk Next 首次提供 Companion API，开始调用该入口 |
| 2025-11 | Zygisk Next 1.3.0 重写加载链，进入"容易踩中"的版本窗口 |
| 2026-01 | 社区集中报告（Zygisk Next #293） |
| 2026 年内 | Zygisk Next 连续几次调整后，该路径不再被触发 |

所以它不是"季节性 bug"，而是**版本窗口型潜伏缺陷**：触发器随 Zygisk 实现变化，
缺陷本身一直在。当前 Zygisk Next 1.4+ 上通常无法复现。

## 5. 修复

只改**每个 ABI 的 1 个字节**：把条件选择指令的条件码从 `EQ` 改成 `LE`，
让 `read() <= 0`（EOF 和 `EAGAIN`）都走 `close` + 返回。

| ABI | 文件偏移 | 原字节 → 新字节 | 指令 |
|---|---|---|---|
| arm64-v8a | `0xa6c5` | `0x01` → `0xd1` | `csel …,eq` → `csel …,le` |
| armeabi-v7a | `0x7e3c` | `0x04` → `0xdc` | `itt eq` → `itt le` |
| x86 | `0x9dd7` | `0x44` → `0x4e` | `cmove` → `cmovle` |
| x86_64 | `0xb318` | `0x44` → `0x4e` | `cmove` → `cmovle` |

正常路径（读到完整握手）行为不变；只有失败分支从"无限重试"变成"关闭并返回"。

## 6. 实现约束

- **版本门禁**：先核对增强模块 `module.prop` 的 `version` / `versionCode`
  必须为 `v29.0.1` / `89`，再核对目标 ABI 的原始 `sha256`。
  任一不符即拒绝，**不修改任何文件**，并提示「仅支持 v29.0.1，
  该缺陷只存在于这一版」。
- **白名单**：4 个 ABI 的原始 / 补丁后哈希全部内置，未知版本一律 fail-closed。
- **原地写**：Zygisk 在开机时会缓存 `.so` 的 fd，换 inode（`mv` / 重新创建）不会生效，
  必须原地改同一 inode（`dd conv=notrunc`）。写入后立即做全文件 `sha256` 复核，
  失败则回滚；回滚也失败时提示用备份恢复。
- **备份**：首次应用写 `<abi>.so.sieof-orig`；即使备份丢失，也能从补丁版反推原版
  （单字节可逆）。
- **热重载**：应用后杀掉现有 companion，Zygisk 会在下次请求时用新文件重建，
  通常无需重启手机。

## 7. 验证

- **模拟器**（4 个 ABI，用真实 `.so` + libc 桩）：补丁前 `cmd 1/2/3 + EOF/EAGAIN`
  在 200 万步上限内不返回；补丁后 900–1800 步内返回，`close` 2 次，成功路径步数不变。
- **真机**（OnePlus PJZ110 / Android 17 / Zygisk Next 1.5.2）：
  从运行中的 companion 内存读出 `base+0xa6c4` = `29 d1 88 1a`（补丁后指令）；
  隔离应用挂载正常，companion 线程数与 CPU 无异常。
- **回归**：`tools/so.test.sh` 覆盖 fail-closed、版本门禁、只读性；
  WebUI 的 79 条用例覆盖状态渲染与并发。

## 8. 限制与回滚

- 该缺陷在当前 Zygisk Next（1.4+）上通常**无法复现**，本功能属于预防性修复，
  面板内已如实说明，不承诺「已修复」。
- 只适用于增强模块 v29.0.1；升级/降级该模块后，请重新 `check`。
- 还原：面板「还原原版」，或 `sh scripts/si-patch.sh so restore`；
  文件被改成未知版本但 `.sieof-orig` 有效时，用 `so restore --force`。
- **卸载本模块前先点「还原原版」**：`uninstall.sh` 只清理 `main.dex`，
  不会撤销 `.so` 补丁。

## 9. 命令行

```sh
sh scripts/si-patch.sh so check     # 只读：SO_STATE / ABI / 版本 / 备份状态
sh scripts/si-patch.sh so apply     # 应用（原地 1 字节，先备份后校验）
sh scripts/si-patch.sh so restore   # 还原原版
sh scripts/si-patch.sh so restore --force   # 未知版本但备份有效时从备份恢复
```
