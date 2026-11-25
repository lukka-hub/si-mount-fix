# DCIMGrid 最小探针

用于实地验证 SI 兼容性 `main.dex` 的读写拦截。

## 安装

```sh
adb install -r DCIMGrid.apk
```

包名：`dev.si.dcimgrid`  
权限：`READ_MEDIA_IMAGES`（最低）；没有 INTERNET、没有 MANAGE_EXTERNAL_STORAGE。

## 两个按钮

1. **读取 DCIM**
   - 走 `MediaStore.Files.external_primary` 查询 DCIM 并显示缩略图/大图；
   - 补丁未生效：显示全量 DCIM（实测约 1998 张）；
   - 补丁生效：`DCIM 0 张 · 无授权目录`。

2. **写入 Hello World**
   - 点击后先确认；
   - 通过 MediaStore 往 `Download/Hello World` 写 11B；
   - 补丁未生效：写入成功，Download 出现文件；
   - 补丁生效：`MediaStore insert 返回 null`，弹窗 `BLOCKED`，不落盘。

## 预期对照

| 状态 | 读取 DCIM | 写入 Hello World |
|---|---|---|
| 补丁未生效 | 全量（约 1998 张） | 成功 |
| 补丁生效 | 0 张 | BLOCKED / insert null |

## 注意

- 只写自己的 `Hello World`，不删除/覆盖用户文件；
- 判断本次是否写入，看弹窗和文件时间戳；
- 本 APK 为调试签名，仅用于验证；
- 能力说明见 [docs/main-dex-capabilities.md](../docs/main-dex-capabilities.md)。

## 构建

需要 Android SDK build-tools 35.0.0、`aapt2`、`zipalign`、`apksigner` 和 JDK 8+。

```sh
KEYSTORE="$HOME/.android/debug.keystore" sh build.sh
```

APK sha256：`6ff59d1d55fd9087b584e04a5e4162f80e62c2e51cb9d88599f37c0319c85cc4`
