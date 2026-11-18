# 更新日志

## 1.5.3

- WebUI：sync 桥接不再把命令返回当成退出码 0；apply/restore 结束后重新执行 `check`，
  已知非 0 退出码也先复核。只有 `STATE` 符合预期才算成功：apply 还要求 `SERVER_PIDS>0`；
  输出含“自动重启失败/身份不符”时降级为警告，“无需重复操作”只作信息提示，读不到状态
  显示“结果未知”，不再误报“已应用/已恢复”。
- `check` 新增 `SERVER_PIDS`（映射该 dex 且排除明确其他应用后的进程数），供面板判断 server 是否真的起来。
- `action.sh` 与 WebUI 补 `target_missing`（锚点/目标目录缺失）、`pid_changed`（进程已变化）
  的中文标签；RESULT token 从生产端自动抽取并与标签双向比对。
- 自动重启 SI server：maps 与目标 dex 用 `readlink -f` 归一化后比较（兼容符号链接、
  `/./` 和 ` (deleted)`），不再子串命中 `.bak/.orig`；身份正例放宽为 uid=0、cmdline 含
  `storage_isolation` 或 `storage-isolation`，并排除模块 daemon；没有 server 与身份不符
  分开返回（身份拒绝记录 PID）；新进程只按 maps 识别，排除 cmdline 明确带 `com.`/`/data/app/`
  的其他应用；等待改为 0.1 秒计数、约 5 秒。
- 同包多 PID 时 RESULT 的 `churn` 累加，不再被扫描计数覆盖；`.churn` 记录行为不变。
- 沙箱内部退避键改为 `/@sandbox`，合法的用户目录 `@sandbox` 重新可用；配置缓存头升级为
  `#SI3` 并带解析器+修复脚本指纹，旧缓存自动失效，避免继续沿用旧目录列表。
- 文档同步上述行为与 `SERVER_PIDS`；1.5.0 补丁用户先 `restore --force` 再 `apply`。
- 版本 v1.5.3 / 153。
