# download_image

网页图片抓取下载器（Flutter，支持 Android / Windows / macOS）。

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## 打包与发布

### 本地打包

```bash
# Android：产物 build/app/outputs/flutter-apk/app-release.apk
# 有 android/key.properties 时用正式签名，否则自动回退 debug 签名
flutter build apk --release

# macOS：先构建，再打成 dmg，产物 dist/download_image-<version>-macos.dmg
flutter build macos --release
bash scripts/package_macos.sh

# Windows：先构建，再用 Inno Setup 编译安装器
# 产物 windows\installer\Output\download_image-<version>-windows-x64-setup.exe
flutter build windows --release
iscc /DMyAppVersion=1.0.0 windows\installer\download_image.iss
```

### Android 签名配置

release 签名读的是 `android/key.properties`（已在 `.gitignore` 中，**切勿提交**）：

```properties
storePassword=<keystore 口令>
keyPassword=<key 口令>
keyAlias=download_image
storeFile=/绝对路径/download_image-release.jks
```

文件不存在时 `build.gradle.kts` 会回退到 debug 签名，方便没有 keystore 的机器上跑 `flutter run --release`。

### CI

- `.github/workflows/ci.yml`：push 到 `main` 或开 PR 时跑 `flutter analyze` + `flutter test test/`
- `.github/workflows/release.yml`：推 `v*` tag 或手动触发，三个平台并行构建，产物汇总后发布到 GitHub Release

```bash
git tag v1.0.0
git push origin v1.0.0
```

需要在仓库 Settings → Secrets and variables → Actions 配置：

| Secret | 说明 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | keystore 文件的 base64（`base64 -i download_image-release.jks \| pbcopy`） |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 口令 |
| `ANDROID_KEY_ALIAS` | key 别名 |
| `ANDROID_KEY_PASSWORD` | key 口令 |

未配置时 Android 会以 debug 签名产出，其余平台不受影响。

### 安装包说明

- **macOS dmg 未做签名与公证**，他人首次打开会被 Gatekeeper 拦截：右键点 App 选「打开」，或执行 `xattr -dr com.apple.quarantine /Applications/download_image.app`
- **Windows 安装器界面为英文**：Inno Setup 6 不自带简体中文语言文件，需要中文界面时得把 `ChineseSimplified.isl` 纳入仓库
