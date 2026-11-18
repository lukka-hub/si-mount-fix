# 更新日志

## 1.5.8

- 修复微信 isolated 子进程导致的假沙箱丢失日志；真实丢失仍会重建。微信按需拉起的 `com.tencent.mm:xweb_sandboxed_process_0…` 等子进程 uid 在 90000–99999，本来就没有 `/storage`，不是 SI 的隔离对象：扫描直接跳过，不再对这类进程探测/写 180 秒退避/计 broken；漏到重建路径时按 na 跳过（也不写退避）。只有 isolated uid 或从未隔离过（无本 boot seen 证据）的进程才按 na；有 seen 证据的普通应用即使 namespace 里没有存储根，也仍按真实丢失处理，`owner`/`missing` 照旧写 180 秒退避并在下一轮重试。`-n` 体检与真跑使用同一套 na/重建判定。
- `.sandbox_seen` 的重建证据加入进程 uid 与 `/proc/<pid>/stat` 第 22 字段 `starttime`：同一个 namespace inode 被内核回收复用给别的进程时不再假命中；旧格式行按“无证据”处理，回落到“源存在 + 属主匹配”，真实丢失仍会被发现。
- 沙箱日志带 `pid`/`uid`/`ns`/`reason`：`gone` 都会写 180 秒退避，日志统一标“下一轮重试”；`na`（isolated/无 storage，不写退避）标“跳过”。同一事件在退避/重试期间只记一次，事件从本轮报告消失（应用自愈或进程退出）后清掉签名，下一次真丢会重新记。
- main.dex 仍为 88,336 B / sha256 `5413a01b6c49f360f3851af60be8820fcb8a4595d0c15697fcebac88b6d73891`（未改动）。
