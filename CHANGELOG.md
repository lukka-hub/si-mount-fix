# 更新日志

## 1.5.1

- 补丁 dex 改为对官方 SI v355 的 `server-v355.dex` 自行反编译重打（325,984 B）。
- 只改 4 条指令：`IPackageManager.getInstalledPackages(JI)` 和 `getInstalledPackages(II)`
  的返回类型由 `ParceledListSlice` 改为 `PackageInfoList`；两处 `ParceledListSlice.getList()`
  改为 `PackageInfoList.getList()`。
- 其余 386 类、1635 方法（1634 个方法体完全一致）、806 字段不变；新增字符串只有
  `Landroid/content/pm/PackageInfoList;`。
- 重打包时剥离了调试信息（不影响运行逻辑，只影响崩溃堆栈行号），所以体积更接近原版。
- 仍仅适用于 SI 8.8.1 r3684 / server-v355；应用、恢复、强制恢复都需要二次确认。
- 思路由酷安用户「无所事事」提供。
