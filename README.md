# download_image

网页图片抓取下载器 —— 在 App 内置浏览器里打开任意网页，自动滚动扫描整页图片，实时汇总成可筛选、可预览、可批量下载的列表。

Flutter 单代码库，交付目标为 **Android / Windows / macOS**（`ios/` 目录是 `flutter create` 生成的，暂未作为交付目标）。

## 功能

- **内置浏览器**：地址栏、前进 / 后退、加载进度、错误页
- **自动整页扫描**：注入 JS 用 `PerformanceObserver` + `MutationObserver` + 全量 DOM 扫描，滚动时增量回传，不必等整轮扫描结束
- **筛选与去重**：最小边滑块、格式 / 来源筛选、两级去重，`srcset` 自动取最大候选
- **预览**：大图缩放预览、复制图片直链
- **批量下载**：Android 存入系统相册，桌面写入系统下载目录
- **动态图 / 防盗链**：优先在页面内 `fetch` 取 blob 分块回传（绕开 Referer 校验），失败降级为 Dio 原生直下
- **页面切换提示**：切换页面时询问是否清空上一页抓到的图片
- **响应式布局**：≥900dp 左右分栏（面板可拖拽调宽、可折叠），窄屏改用底部抽屉

## 环境要求

| 项 | 版本 / 说明 |
| --- | --- |
| Flutter | 3.47.4（Dart 3.13.3） |
| JDK | 17 |
| Android | AGP 8.13.0、Gradle 9.3.1 |
| Windows | 需要 WebView2 Runtime（Win11 自带，Win10 部分机型需手动安装，App 启动时会检测） |
| macOS | Xcode 命令行工具 |

## 开发

```bash
flutter pub get
flutter analyze
flutter test test/

flutter run -d macos          # 或 -d windows / -d <android-device-id>
```

端到端集成测试（需要真机或模拟器）：

```bash
flutter test integration_test/js_capture_test.dart -d <device-id>
```

## 下载安装

从 [Releases](https://github.com/LingRen/download_image/releases) 下载对应平台产物：

| 平台 | 文件 |
| --- | --- |
| Android | `download_image-<version>-android.apk` |
| Windows | `download_image-<version>-windows-x64-setup.exe` |
| macOS | `download_image-<version>-macos.dmg` |

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

## 项目结构

```text
lib/
  app/         入口与布局（900dp 断点：左右分栏 / BottomSheet）
  core/        领域模型、JS↔Dart 桥协议
  features/
    browser/   WebView、地址栏、导航状态、URL 规范化
    capture/   注入脚本、抓取聚合、筛选、去重
    gallery/   图片面板、筛选栏、网格、预览页
    download/  下载调度、blob 分块接收、平台落盘
```
