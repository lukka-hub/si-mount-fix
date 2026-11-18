# 更新日志

## 1.5.5

- **自建 main.dex**：`assets/main.dex` 换成模块自行反编译重打的版本（88,336 B / sha256
  `5413a01b6c49f360f3851af60be8820fcb8a4595d0c15697fcebac88b6d73891`），不再使用社区版
  （99,104 B / `6d4058bc…`）。只改 4 条 invoke：两个 `getInstalledPackages` 的返回类型改为
  `PackageInfoList`，两处 `getList` 的 owner 改为 `PackageInfoList`；其余 112 类、446 方法、
  231 字段不变，重打包时剥离调试信息；与社区版反汇编后 112 个 smali 逐字节相同。
  原版仍为 90,740 B / `a407…`。自建版仍建议先在目标机型抓 logcat 验证。
- **U1 卸载保留备份**：`uninstall.sh` 不再自动恢复 main.dex。只要 `patch-backup/main.dex.*`
  存在就只保留该目录并打印路径，其他运行期数据照旧删除；保留不依赖 `BACKUP_OK`/`sha256sum`
  是否可用，没有 main.dex 备份才删除。需要恢复请在卸载前手动运行 `restore --force`。
- **U2 版本门禁**：`restore`/`restore --force` 在 zygisk 模块版本不匹配（`SI_MATCH=0`）时拒绝；
  WebUI 的「强制恢复」在版本不匹配时隐藏/置灰，避免用旧版本备份覆盖。
- **U3 结果与提示**：restore 成功后卡片显示“已恢复原版，重启生效”，不再显示“未做任何修改”；
  超时/读不到退出码统一显示“结果未知，请刷新检查”，不直接判失败/成功；动作失败/超时不写
  状态缓存、不置 prompted，下次打开重新 check；check 进行中动作按钮置灰并提示“检查中”。
  `loadPatch` 会清掉旧的动作结果；首次提示标记改为按目标文件+适用版本区分，同一目标不重复弹。
- **UI 不卡死**：补丁检查、体检/修复、重启守护、保存配置、apply/restore 全部改为后台执行 +
  300ms 轮询，单次 exec 只做启动/读结果；按钮改为独立 busy，只禁用被点的按钮；补丁状态增加
  30 秒缓存（30 秒内直接复用，过期后校验 mtime+size+sha）与手动「检查补丁」入口，
  刷新链不再强制跑 check；check 8 秒、
  fix 30 秒、restart 10 秒超时并显示“检查耗时/超时”反馈。补丁动作后只做一次 `stat+sha256`
  复核，补丁链路不再全量 check，也没有 `/proc` 全扫。
- 版本 v1.5.5 / 155。
