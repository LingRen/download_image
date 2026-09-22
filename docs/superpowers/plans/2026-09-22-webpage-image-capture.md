# 网页图片抓取下载器 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付一个跨端 Flutter App，在 App 内置浏览器打开任意网页后自动滚动扫描整页图片，实时汇总为可筛选、可预览、可批量下载（相册 / 下载目录）的图片列表。

**Architecture:** Flutter 单代码库 + `flutter_inappwebview`。抓取主通道是**注入 JS**（`PerformanceObserver` + `MutationObserver` + 全量 DOM 扫描）→ 通过唯一的 JS↔Dart 桥协议（handler 名 `imgcat`）增量回传；下载主通道同样走 JS（页面内 `fetch` 取 blob，512KB 分块 base64 回传，绕开防盗链），失败降级为 Dio 原生直下。平台差异只允许出现在 `download/save_target.dart` 与 `features/browser/` 的平台增强处，其余模块（`capture` / `gallery`）为纯逻辑 + 纯 UI，可独立测试。

**Tech Stack:** Flutter 3.47.4 / Dart 3.13.3、flutter_inappwebview 6.x、path_provider、path、dio、gal、app_settings；测试用 `flutter_test` + `integration_test`。

---

## 0. 背景与范围

设计文档（已批准）：
[docs/superpowers/specs/2026-09-22-webpage-image-capture-design.md](file:///Users/ling/code/download_image/docs/superpowers/specs/2026-09-22-webpage-image-capture-design.md)

本计划实现设计文档第 3–12 节的全部一期内容，覆盖验收标准 1–7。

### 本期明确不做（写代码时不要顺手加）

| 不做项 | 说明 |
|---|---|
| zip 打包下载 | 二期 |
| 历史记录 | 二期 |
| App 内下载管理器 | 二期 |
| Android / Windows 请求级拦截（`shouldInterceptRequest` / `WebResourceRequested`） | 设计第 2、3 条：抓取主通道不依赖平台拦截，这是「可选增强」，二期再做 |
| 桌面端自定义下载目录 | 一期只写系统下载目录 |
| `shared_preferences` 等本地持久化 | 一期无持久化需求（历史记录是二期） |

### 工具链约定（每条命令都必须用绝对路径）

`flutter` 不在 PATH，`fvm default` 软链已失效（指向不存在的 3.35.2），**不要用 `fvm flutter`**：

```bash
FLUTTER=/Users/ling/fvm/versions/3.47.4/bin/flutter
```

本机环境事实（已实测）：Flutter 3.47.4 / Dart 3.13.3；Android SDK 36.0.0 可用；Xcode 27.0 可用但 **iOS 模拟器运行时未安装**（iOS 冒烟测试需要先在 Xcode 里下载模拟器运行时）；macOS 桌面可直接运行；Windows 端无法在本机验证。

---

## 1. 文件结构

写代码前先锁定分解方案。每个文件一个明确职责，改动时通常一起改的文件放在一起。

```text
lib/
  main.dart                        应用入口：WebView2 检测 + runApp
  app/
    app.dart                       MaterialApp、主题、把 HomeShell 作为 home
    home_shell.dart                900dp 断点布局：左右分栏 / 全屏 + BottomSheet
    breakpoints.dart               kPanelBreakpoint = 900，列数计算
  core/
    model/
      image_asset.dart             ImageAsset 领域模型 + ImageSource 枚举 + fromJson/toJson/merge
    bridge/
      bridge_protocol.dart         JS↔Dart 消息定义与解析（batch / scan / blob）
      js_channel.dart              JsChannel 抽象 + JsChannelHolder（WebView 就绪前的占位）
  features/
    browser/
      browser_page.dart            WebView + 地址栏 + 进度 + 桥回调转发 + 扫整页控制 + 错误页
      browser_controller.dart      导航状态（进度 / 可后退 / 可前进 / 错误文本）
      url_normalizer.dart          用户输入 → 合法 http(s) URL
      webview_js_channel.dart      JsChannel 的真实实现（包 InAppWebViewController）
      platform/
        webview2_check.dart        Windows: WebView2 Runtime 检测
    capture/
      capture_script.dart          注入 JS 全文（kCaptureScript）
      capture_controller.dart      ChangeNotifier：聚合图片、扫描状态、筛选、选中态
      srcset.dart                  srcset 解析 + 取最大候选（纯逻辑）
      image_filter.dart            FilterSettings + 过滤规则（纯逻辑）
      deduplicator.dart            两级去重 + variantKey（纯逻辑）
    gallery/
      image_panel.dart             图片面板：筛选栏 + 网格 + 底部操作栏 + 空态
      filter_bar.dart              最小边滑块、格式 chip、来源 chip、去重开关
      image_grid.dart              自适应网格 + 缩略图 + 角标 + 多选圈 + 失败标红
      image_preview_page.dart      大图预览（可缩放）+ 复制直链 + 下载这张
    download/
      blob_file_writer.dart        分块接收并写临时文件（纯逻辑 + dart:io）
      file_name.dart               从 URL / MIME 推导文件名与扩展名（纯逻辑）
      download_service.dart        首选 blob 通道、降级 Dio 原生直下
      download_controller.dart     ChangeNotifier：下载队列、每项状态、进度、失败重试
      webview_blob_fetcher.dart    通过 JS 桥取 blob 并落盘
      native_fetcher.dart          Dio 下载到临时文件（带 Cookie / Referer）
      save_target.dart             保存目标：相册 / 下载目录（平台差异只在这里）

test/
  support/fake_download.dart       下载模块的共用测试替身（FakeDownloadExecutor / FakeBlobSink）
  core/bridge/bridge_protocol_test.dart
  core/model/image_asset_test.dart
  features/browser/url_normalizer_test.dart
  features/capture/srcset_test.dart
  features/capture/image_filter_test.dart
  features/capture/deduplicator_test.dart
  features/capture/capture_controller_test.dart
  features/download/blob_file_writer_test.dart
  features/download/file_name_test.dart
  features/download/save_target_test.dart
  features/download/download_controller_test.dart
  features/gallery/image_panel_test.dart
  app/home_shell_test.dart

integration_test/
  js_capture_test.dart             HTML fixture 抓取断言 + blob 分块通道端到端
```

**边界约定（违反即为架构缺陷）**

- JS 只发一种消息格式，Dart 只解析这一种；抓取与下载共用 `core/bridge`。
- 平台判断（`Platform.isAndroid` 等）只允许出现在 `download/save_target.dart`、`features/browser/platform/webview2_check.dart`、`features/browser/browser_page.dart` 的崩溃重建处。
- `features/capture/*` 与 `features/gallery/*` 不 import `dart:io`、不 import `flutter_inappwebview`，保证可纯单测。

---

## Task 1: 项目脚手架与依赖

**Files:**
- Create: `pubspec.yaml`、`lib/main.dart`、`android/`、`ios/`、`macos/`、`windows/`（均由 `flutter create` 生成）
- Delete: `test/widget_test.dart`
- Modify: `.gitignore`（校验 `flutter create` 未覆盖自定义条目）

- [ ] **Step 1: 生成四端工程**

Run（工作目录 `/Users/ling/code/download_image`）:

```bash
/Users/ling/fvm/versions/3.47.4/bin/flutter create --platforms=macos,windows,android,ios --org com.example --project-name download_image .
```

Expected: 输出 `All done!`，目录下出现 `pubspec.yaml`、`lib/main.dart`、`android/`、`ios/`、`macos/`、`windows/`、`test/widget_test.dart`。

- [ ] **Step 2: 校验 .gitignore 没被覆盖**

Run:

```bash
git -C /Users/ling/code/download_image diff --stat .gitignore && git -C /Users/ling/code/download_image status --short
```

Expected: 若 diff 显示 `.superpowers/` 那一行被删除，就手动补回 `.gitignore` 末尾这两行，然后重跑本步：

```text
# Superpowers brainstorming companion
.superpowers/
```

- [ ] **Step 3: 删除模板测试**

删除 `test/widget_test.dart`（它测试的是模板计数器 App，会在后续任务里永远失败）。

- [ ] **Step 4: 添加依赖（不写死版本号，交给 pub 解析）**

Run:

```bash
/Users/ling/fvm/versions/3.47.4/bin/flutter pub add flutter_inappwebview path_provider path dio gal app_settings
```

Expected: 输出 `Changed N dependencies!`，`pubspec.yaml` 的 `dependencies` 里出现这 6 个包。

说明：`app_settings` 用于实现设计文档第 9 节「相册权限被拒 → 引导跳转系统设置」，是唯一新增的决策，理由是不自己写平台通道。

- [ ] **Step 5: 添加 integration_test（Edit pubspec.yaml，不用 pub add，避免 sdk 依赖语法坑）**

把 `pubspec.yaml` 的 `dev_dependencies` 改为：

```yaml
dev_dependencies:
  flutter_test:
    sdk: flutter
  integration_test:
    sdk: flutter
  flutter_lints: ^6.0.0
```

（`flutter_lints` 的版本号保留 `flutter create` 生成的原值，不要改。）

Run:

```bash
/Users/ling/fvm/versions/3.47.4/bin/flutter pub get
```

Expected: `Got dependencies!`

- [ ] **Step 6: 验证工程健康**

Run:

```bash
/Users/ling/fvm/versions/3.47.4/bin/flutter analyze
```

Expected: `No issues found!`

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "chore: 初始化 Flutter 四端工程与依赖"
```

---

## Task 2: 平台可行性验证（阻塞式 Spike）

设计文档第 11 节风险表第一行要求：**实施第一步先验证 WebView 能否加载页面、JS 注入能否执行、`callHandler` 能否回传**。本任务不通过就不许往下做。

**Files:**
- Modify: `lib/main.dart`（本任务的临时内容，Task 17 会替换为定稿版本）
- Create: `lib/features/browser/browser_page.dart`（最小版本，Task 11 会整体替换）

- [ ] **Step 1: 写最小验证页**

`lib/features/browser/browser_page.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 临时探针：只验证「页面能加载 + 注入 JS 能执行 + callHandler 能回传」。
/// Task 11 会把这个文件整体替换为正式实现。
const String _probeScript = '''
(function () {
  function fire() {
    if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) return false;
    window.flutter_inappwebview.callHandler('imgcat', JSON.stringify({
      type: 'batch',
      pageUrl: location.href,
      assets: [{ url: location.href + 'probe.png', w: 120, h: 80, size: 1024, mime: 'image/png', source: 'img' }]
    }));
    return true;
  }
  var timer = setInterval(function () { if (fire()) clearInterval(timer); }, 200);
  setTimeout(function () { clearInterval(timer); }, 10000);
})();
''';

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key, required this.initialUrl});

  final Uri initialUrl;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  String _received = '（尚未收到协议消息）';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text('收到协议消息: $_received', key: const Key('probe-output')),
        ),
        Expanded(
          child: InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl.toString())),
            initialUserScripts: UnmodifiableListView<UserScript>([
              UserScript(
                source: _probeScript,
                injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                forMainFrameOnly: false,
              ),
            ]),
            onWebViewCreated: (controller) {
              controller.addJavaScriptHandler(
                handlerName: 'imgcat',
                callback: (args) {
                  final raw = args.isNotEmpty ? args.first : null;
                  setState(() => _received = raw?.toString() ?? 'null');
                  return null;
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
```

- [ ] **Step 2: 写临时入口**

`lib/main.dart`：

```dart
import 'package:flutter/material.dart';

import 'features/browser/browser_page.dart';

void main() => runApp(const SpikeApp());

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spike',
      home: Scaffold(
        appBar: AppBar(title: const Text('平台可行性验证')),
        body: BrowserPage(initialUrl: Uri.parse('https://example.com')),
      ),
    );
  }
}
```

- [ ] **Step 3: macOS 验证（本机可做）**

Run:

```bash
/Users/ling/fvm/versions/3.47.4/bin/flutter run -d macos
```

Expected（判定标准，三条全中才算通过）：
1. 窗口里 `example.com` 页面渲染出来（能看到 "Example Domain" 标题）；
2. 顶部文字从「（尚未收到协议消息）」变成 `收到协议消息: {"type":"batch","pageUrl":"https://example.com/",...}`；
3. 终端无 `MissingPluginException` / 崩溃日志。

判定完成后按 `q` 退出。

- [ ] **Step 4: Windows 验证（需 Windows 机器）**

在 Windows 机器上拉取本仓库同一 commit，然后用该机器的 Flutter 执行：

```bash
flutter run -d windows
```

Expected: 与 Step 3 完全相同的三条判定。

- 若本机没有 Windows 机器：本步标记为**未验证**，继续后续任务，但在最终交付说明中必须写明「Windows 端代码就绪但未验证」。
- 若 Windows 上三条判定未全中（WebView 不渲染 / 注入脚本不执行 / `callHandler` 无回传）：**Windows 移出一期**，只交付 macOS + Android + iOS 三端；把结论追加到本任务末尾，并停止后续任何 Windows 专属工作。

- [ ] **Step 5: 记录实测结果**

在本任务末尾追加一行实测结论（平台、日期、通过/未通过、备注）。这是设计文档第 11 节的交付物，不要省略。

- [ ] **Step 6: 提交**

```bash
git add lib/main.dart lib/features/browser/browser_page.dart docs/superpowers/plans/2026-09-22-webpage-image-capture.md
git commit -m "spike: 验证四端 WebView 注入与 JS 桥回传可行性"
```

**实测结论：**

| 平台 | 日期 | 结果 | 备注 |
|---|---|---|---|
| macOS | 2026-09-22 | **通过** | 三条判定全中：①`example.com` 正常渲染（payload `title:"Example Domain"`）；②`callHandler` 回传成功（stdout `SPIKE_HANDLER_RECEIVED: {"type":"batch","pageUrl":"https://example.com/","title":"Example Domain",...}`）；③无 `MissingPluginException` / 崩溃。构建前需为 `DebugProfile.entitlements` 与 `Release.entitlements` 追加 `com.apple.security.network.client`（macOS 沙盒缺此权限则无法出站联网，页面加载必失败）。另：本机在沙箱内执行 xcodebuild 会报 `sandbox-exec: sandbox_apply: Operation not permitted`，需在非沙箱环境构建。 |
| Windows | 2026-09-22 | **未验证** | 本机无 Windows 机器，无法执行 Step 4。Windows 端代码就绪但未验证，后续交付说明须写明。 |
| Android | — | 待 Task 18 冒烟 | 本任务未覆盖。 |
| iOS | — | 待 Task 18 冒烟 | 本机 iOS 模拟器运行时未安装，本任务不尝试。 |

---

## Task 3: ImageAsset 领域模型

**Files:**
- Create: `lib/core/model/image_asset.dart`
- Test: `test/core/model/image_asset_test.dart`

- [ ] **Step 1: 写失败的测试**

`test/core/model/image_asset_test.dart`：

```dart
import 'package:download_image/core/model/image_asset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ImageAsset', () {
    test('尺寸齐全时 sizeKnown 为 true，minSide 取较小边', () {
      const asset = ImageAsset(url: 'https://a.com/x.jpg', width: 300, height: 200);
      expect(asset.sizeKnown, isTrue);
      expect(asset.minSide, 200);
    });

    test('缺少任一边时 sizeKnown 为 false，minSide 为 0', () {
      const asset = ImageAsset(url: 'https://a.com/x.jpg', width: 300);
      expect(asset.sizeKnown, isFalse);
      expect(asset.minSide, 0);
    });

    test('fromJson 解析 JS 侧字段，未知 source 回退为 img', () {
      final asset = ImageAsset.fromJson(const {
        'url': 'https://a.com/x.jpg',
        'w': 900,
        'h': 600,
        'size': 20480,
        'mime': 'image/jpeg',
        'source': 'cssBackground',
      });
      expect(asset.url, 'https://a.com/x.jpg');
      expect(asset.width, 900);
      expect(asset.height, 600);
      expect(asset.byteSize, 20480);
      expect(asset.mimeType, 'image/jpeg');
      expect(asset.source, ImageSource.cssBackground);

      final unknown = ImageAsset.fromJson(const {'url': 'https://a.com/y.png', 'source': 'whatever'});
      expect(unknown.source, ImageSource.img);
      expect(unknown.width, isNull);
    });

    test('toJson 与 fromJson 往返一致', () {
      const asset = ImageAsset(
        url: 'https://a.com/x.webp',
        width: 10,
        height: 20,
        byteSize: 3,
        mimeType: 'image/webp',
        source: ImageSource.srcset,
      );
      final again = ImageAsset.fromJson(asset.toJson());
      expect(again.url, asset.url);
      expect(again.width, asset.width);
      expect(again.height, asset.height);
      expect(again.byteSize, asset.byteSize);
      expect(again.mimeType, asset.mimeType);
      expect(again.source, asset.source);
    });

    test('merge 保留已知尺寸、较大尺寸与非空字段', () {
      const a = ImageAsset(url: 'https://a.com/x.jpg', width: 300, height: 300, source: ImageSource.img);
      const b = ImageAsset(url: 'https://a.com/x.jpg', width: 900, height: 900, mimeType: 'image/jpeg', source: ImageSource.dynamic);

      final merged = a.merge(b);
      expect(merged.width, 900);
      expect(merged.height, 900);
      expect(merged.mimeType, 'image/jpeg');
      expect(merged.source, ImageSource.img, reason: '保留先出现的来源，来源更具体的信息不丢');

      final mergedBack = b.merge(a);
      expect(mergedBack.width, 900);
      expect(mergedBack.mimeType, 'image/jpeg');
      expect(mergedBack.source, ImageSource.dynamic);
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/core/model/image_asset_test.dart`

Expected: FAIL，报 `Error: Couldn't resolve the package 'download_image'` 或 `Undefined name 'ImageAsset'`。

- [ ] **Step 3: 写最小实现**

`lib/core/model/image_asset.dart`：

```dart
/// 图片来源，对应设计文档第 5 节的四个枚举值。
enum ImageSource { img, srcset, cssBackground, dynamic }

/// 抓取到的一张图片。字段与 JS 侧 payload 一一对应。
class ImageAsset {
  const ImageAsset({
    required this.url,
    this.mimeType,
    this.width,
    this.height,
    this.byteSize,
    this.source = ImageSource.img,
  });

  /// 已归一化的绝对 URL。
  final String url;
  final String? mimeType;
  final int? width;
  final int? height;

  /// 来自 PerformanceEntry 的传输体积，可能为空。
  final int? byteSize;
  final ImageSource source;

  /// 宽高都已知才为 true。尺寸未知的图片不参与尺寸过滤。
  bool get sizeKnown => width != null && height != null;

  /// 较小边；尺寸未知时为 0。
  int get minSide {
    if (!sizeKnown) return 0;
    return width! < height! ? width! : height!;
  }

  factory ImageAsset.fromJson(Map<String, dynamic> json) {
    return ImageAsset(
      url: json['url'] as String,
      mimeType: json['mime'] as String?,
      width: (json['w'] as num?)?.toInt(),
      height: (json['h'] as num?)?.toInt(),
      byteSize: (json['size'] as num?)?.toInt(),
      source: ImageSource.values.firstWhere(
        (value) => value.name == json['source'],
        orElse: () => ImageSource.img,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'mime': mimeType,
        'w': width,
        'h': height,
        'size': byteSize,
        'source': source.name,
      };

  /// 同一 URL 的两次抓取结果合并：尺寸取更大者、非空字段补全、来源保留先出现的。
  ImageAsset merge(ImageAsset other) {
    assert(other.url == url, '只能合并同一 URL');
    final otherArea = other.sizeKnown ? other.width! * other.height! : -1;
    final selfArea = sizeKnown ? width! * height! : -1;
    final useOtherDims = otherArea > selfArea;
    return ImageAsset(
      url: url,
      mimeType: mimeType ?? other.mimeType,
      width: useOtherDims ? other.width : width,
      height: useOtherDims ? other.height : height,
      byteSize: byteSize ?? other.byteSize,
      source: source,
    );
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/core/model/image_asset_test.dart`

Expected: `All tests passed!`

- [ ] **Step 5: 提交**

```bash
git add lib/core/model/image_asset.dart test/core/model/image_asset_test.dart
git commit -m "feat(model): 新增 ImageAsset 领域模型"
```

---

## Task 4: 地址栏 URL 归一化

**Files:**
- Create: `lib/features/browser/url_normalizer.dart`
- Test: `test/features/browser/url_normalizer_test.dart`

- [ ] **Step 1: 写失败的测试**

`test/features/browser/url_normalizer_test.dart`：

```dart
import 'package:download_image/features/browser/url_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeInputUrl', () {
    test('省略协议时补 https', () {
      expect(normalizeInputUrl('example.com/a'), 'https://example.com/a');
    });

    test('保留已有 http / https 协议', () {
      expect(normalizeInputUrl('http://example.com/a'), 'http://example.com/a');
      expect(normalizeInputUrl('https://example.com/a?b=1'), 'https://example.com/a?b=1');
    });

    test('去掉首尾空白', () {
      expect(normalizeInputUrl('   example.com  '), 'https://example.com');
    });

    test('非 http(s) 协议抛 FormatException', () {
      expect(() => normalizeInputUrl('ftp://example.com/a'), throwsFormatException);
      expect(() => normalizeInputUrl('javascript:alert(1)'), throwsFormatException);
    });

    test('空串或缺少主机名抛 FormatException', () {
      expect(() => normalizeInputUrl(''), throwsFormatException);
      expect(() => normalizeInputUrl('   '), throwsFormatException);
      expect(() => normalizeInputUrl('https:///a'), throwsFormatException);
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/features/browser/url_normalizer_test.dart`

Expected: FAIL，`Couldn't resolve the package` / `Undefined name 'normalizeInputUrl'`。

- [ ] **Step 3: 写最小实现**

`lib/features/browser/url_normalizer.dart`：

```dart
/// 把用户在地址栏输入的内容归一化成合法的 http(s) 绝对 URL。
/// 只在地址栏入口使用；页面内抓到的 URL 由 JS 侧 `new URL(u, location.href)` 处理。
String normalizeInputUrl(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('请输入网址');
  }
  final candidate = trimmed.contains('://') ? trimmed : 'https://$trimmed';
  final uri = Uri.parse(candidate);
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw FormatException('只支持 http / https，收到：${uri.scheme}');
  }
  if (uri.host.isEmpty) {
    throw const FormatException('网址缺少主机名');
  }
  return uri.toString();
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/features/browser/url_normalizer_test.dart`

Expected: `All tests passed!`

- [ ] **Step 5: 提交**

```bash
git add lib/features/browser/url_normalizer.dart test/features/browser/url_normalizer_test.dart
git commit -m "feat(browser): 地址栏 URL 归一化"
```

---

## Task 5: srcset 最大候选解析

**Files:**
- Create: `lib/features/capture/srcset.dart`
- Test: `test/features/capture/srcset_test.dart`

- [ ] **Step 1: 写失败的测试**

`test/features/capture/srcset_test.dart`：

```dart
import 'package:download_image/features/capture/srcset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseSrcset', () {
    test('解析 w 描述符', () {
      final list = parseSrcset('/a.jpg 300w, /b.jpg 900w, /c.jpg 600w');
      expect(list.length, 3);
      expect(list[0].url, '/a.jpg');
      expect(list[0].width, 300);
      expect(list[1].width, 900);
    });

    test('解析 x 描述符，按 1x=1000 折算成可比数值', () {
      final list = parseSrcset('/a.jpg 1x, /b.jpg 2x');
      expect(list[0].width, 1000);
      expect(list[1].width, 2000);
    });

    test('没有描述符时宽度为 null', () {
      final list = parseSrcset('/only.jpg');
      expect(list.single.url, '/only.jpg');
      expect(list.single.width, isNull);
    });

    test('忽略多余空白与空段', () {
      final list = parseSrcset('  /a.jpg   300w ,, /b.jpg 600w  ');
      expect(list.map((e) => e.url).toList(), ['/a.jpg', '/b.jpg']);
    });
  });

  group('pickLargest', () {
    test('取宽度描述符最大的候选', () {
      final best = pickLargest('/a.jpg 300w, /b.jpg 900w, /c.jpg 600w');
      expect(best?.url, '/b.jpg');
      expect(best?.width, 900);
    });

    test('宽度相同时取先出现的', () {
      final best = pickLargest('/a.jpg 900w, /b.jpg 900w');
      expect(best?.url, '/a.jpg');
    });

    test('全部没有描述符时取第一个', () {
      final best = pickLargest('/a.jpg, /b.jpg');
      expect(best?.url, '/a.jpg');
      expect(best?.width, isNull);
    });

    test('空串或 null 返回 null', () {
      expect(pickLargest(''), isNull);
      expect(pickLargest(null), isNull);
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/features/capture/srcset_test.dart`

Expected: FAIL，`Undefined name 'parseSrcset'`。

- [ ] **Step 3: 写最小实现**

`lib/features/capture/srcset.dart`：

```dart
/// srcset 中的一个候选。
class SrcsetCandidate {
  const SrcsetCandidate(this.url, this.width);

  final String url;

  /// 来自 `300w` 描述符的像素宽，或来自 `2x` 描述符折算（1x = 1000）；
  /// 没有描述符时为 null。
  final int? width;
}

/// 解析 srcset 字符串，非法片段被跳过。
List<SrcsetCandidate> parseSrcset(String? srcset) {
  final results = <SrcsetCandidate>[];
  if (srcset == null || srcset.trim().isEmpty) return results;
  for (final raw in srcset.split(',')) {
    final part = raw.trim();
    if (part.isEmpty) continue;
    final fields = part.split(RegExp(r'\s+'));
    final url = fields.first;
    if (url.isEmpty) continue;
    results.add(SrcsetCandidate(url, _parseDescriptor(fields.length > 1 ? fields[1] : null)));
  }
  return results;
}

int? _parseDescriptor(String? descriptor) {
  if (descriptor == null || descriptor.isEmpty) return null;
  final lower = descriptor.toLowerCase();
  final body = lower.substring(0, lower.length - 1);
  if (lower.endsWith('w')) return int.tryParse(body);
  if (lower.endsWith('x')) {
    final scale = double.tryParse(body);
    return scale == null ? null : (scale * 1000).round();
  }
  return null;
}

/// 取像素最大的候选；宽度相同时取先出现的；全部没有描述符时取第一个。
SrcsetCandidate? pickLargest(String? srcset) {
  final candidates = parseSrcset(srcset);
  if (candidates.isEmpty) return null;
  var best = candidates.first;
  for (final candidate in candidates.skip(1)) {
    final bestWidth = best.width ?? -1;
    final width = candidate.width ?? -1;
    if (width > bestWidth) best = candidate;
  }
  return best;
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/features/capture/srcset_test.dart`

Expected: `All tests passed!`

- [ ] **Step 5: 提交**

```bash
git add lib/features/capture/srcset.dart test/features/capture/srcset_test.dart
git commit -m "feat(capture): srcset 最大候选解析"
```

---

## Task 6: 过滤规则与 FilterSettings

**Files:**
- Create: `lib/features/capture/image_filter.dart`
- Test: `test/features/capture/image_filter_test.dart`

- [ ] **Step 1: 写失败的测试**

`test/features/capture/image_filter_test.dart`：

```dart
import 'package:download_image/core/model/image_asset.dart';
import 'package:download_image/features/capture/image_filter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const defaults = FilterSettings();

  group('isFilteredOut', () {
    test('data: 与 blob: 协议一律过滤', () {
      expect(isFilteredOut(const ImageAsset(url: 'data:image/png;base64,AAAA'), defaults), isTrue);
      expect(isFilteredOut(const ImageAsset(url: 'blob:https://a.com/abc'), defaults), isTrue);
    });

    test('最小边小于阈值被过滤（含 1×1 像素）', () {
      expect(isFilteredOut(const ImageAsset(url: 'https://a.com/x.jpg', width: 1, height: 1), defaults), isTrue);
      expect(isFilteredOut(const ImageAsset(url: 'https://a.com/x.jpg', width: 40, height: 1000), defaults), isTrue);
      expect(isFilteredOut(const ImageAsset(url: 'https://a.com/x.jpg', width: 63, height: 900), defaults), isTrue);
    });

    test('恰好等于阈值的保留', () {
      expect(isFilteredOut(const ImageAsset(url: 'https://a.com/x.jpg', width: 64, height: 64), defaults), isFalse);
    });

    test('尺寸未知的不过滤（避免误杀）', () {
      const asset = ImageAsset(url: 'https://a.com/x.jpg');
      expect(asset.sizeKnown, isFalse);
      expect(isFilteredOut(asset, defaults), isFalse);
    });

    test('阈值可调', () {
      const asset = ImageAsset(url: 'https://a.com/x.jpg', width: 100, height: 100);
      expect(isFilteredOut(asset, defaults), isFalse);
      expect(isFilteredOut(asset, const FilterSettings(minSide: 200)), isTrue);
    });

    test('格式不在启用集合里被过滤，jpeg 归一到 jpg', () {
      expect(isFilteredOut(const ImageAsset(url: 'https://a.com/x.png'), defaults), isFalse);
      expect(
        isFilteredOut(const ImageAsset(url: 'https://a.com/x.png'), const FilterSettings(enabledFormats: {'jpg'})),
        isTrue,
      );
      expect(
        isFilteredOut(const ImageAsset(url: 'https://a.com/x.jpeg'), const FilterSettings(enabledFormats: {'jpg'})),
        isFalse,
      );
      expect(
        isFilteredOut(
          const ImageAsset(url: 'https://a.com/x', mimeType: 'image/webp'),
          const FilterSettings(enabledFormats: {'jpg'}),
        ),
        isTrue,
      );
    });

    test('格式无法判断时不过滤', () {
      expect(isFilteredOut(const ImageAsset(url: 'https://a.com/x'), defaults), isFalse);
      expect(isFilteredOut(const ImageAsset(url: 'https://a.com/?id=3'), defaults), isFalse);
    });

    test('来源不在启用集合里被过滤', () {
      const bg = ImageAsset(url: 'https://a.com/x.jpg', width: 300, height: 300, source: ImageSource.cssBackground);
      expect(isFilteredOut(bg, defaults), isFalse);
      expect(
        isFilteredOut(bg, const FilterSettings(enabledSources: {ImageSource.img})),
        isTrue,
      );
    });
  });

  group('formatOf', () {
    test('从路径扩展名识别，带查询串也能识别', () {
      expect(formatOf(const ImageAsset(url: 'https://a.com/x.JPG?w=300')), 'jpg');
      expect(formatOf(const ImageAsset(url: 'https://a.com/x.webp')), 'webp');
      expect(formatOf(const ImageAsset(url: 'https://a.com/x.svg?v=2')), 'svg');
    });

    test('mimeType 优先于扩展名', () {
      expect(formatOf(const ImageAsset(url: 'https://a.com/x.png', mimeType: 'image/gif')), 'gif');
    });

    test('未知格式返回 null', () {
      expect(formatOf(const ImageAsset(url: 'https://a.com/x.avif')), isNull);
      expect(formatOf(const ImageAsset(url: 'https://a.com/x')), isNull);
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/features/capture/image_filter_test.dart`

Expected: FAIL，`Undefined name 'FilterSettings'`。

- [ ] **Step 3: 写最小实现**

`lib/features/capture/image_filter.dart`：

```dart
import '../../core/model/image_asset.dart';

/// 最小边默认阈值（px），设计文档第 8 节。
const int kDefaultMinSide = 64;

/// 一期支持的格式 chip，设计文档第 8 节。
const List<String> kAllFormats = ['jpg', 'png', 'gif', 'webp', 'svg'];

/// 列表筛选设置。不可变，改一项用 copyWith。
class FilterSettings {
  const FilterSettings({
    this.minSide = kDefaultMinSide,
    this.enabledFormats = const {'jpg', 'png', 'gif', 'webp', 'svg'},
    this.mergeVariants = true,
    this.enabledSources = const {
      ImageSource.img,
      ImageSource.srcset,
      ImageSource.cssBackground,
      ImageSource.dynamic,
    },
  });

  final int minSide;
  final Set<String> enabledFormats;

  /// 二级去重开关：同路径尺寸变体只保留最大一张。
  final bool mergeVariants;
  final Set<ImageSource> enabledSources;

  FilterSettings copyWith({
    int? minSide,
    Set<String>? enabledFormats,
    bool? mergeVariants,
    Set<ImageSource>? enabledSources,
  }) {
    return FilterSettings(
      minSide: minSide ?? this.minSide,
      enabledFormats: enabledFormats ?? this.enabledFormats,
      mergeVariants: mergeVariants ?? this.mergeVariants,
      enabledSources: enabledSources ?? this.enabledSources,
    );
  }
}

/// 识别图片格式，统一小写并把 jpeg 归一为 jpg；无法判断时返回 null。
String? formatOf(ImageAsset asset) {
  final mime = asset.mimeType?.toLowerCase();
  if (mime != null && mime.contains('/')) {
    final subtype = mime.split('/').last;
    if (subtype == 'jpeg') return 'jpg';
    if (kAllFormats.contains(subtype)) return subtype;
  }
  final path = Uri.tryParse(asset.url)?.path.toLowerCase() ?? '';
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return null;
  final ext = path.substring(dot + 1);
  if (ext == 'jpeg') return 'jpg';
  return kAllFormats.contains(ext) ? ext : null;
}

/// 是否应从列表中过滤掉。尺寸未知的图片不参与尺寸过滤（设计文档第 8 节）。
bool isFilteredOut(ImageAsset asset, FilterSettings settings) {
  final scheme = Uri.tryParse(asset.url)?.scheme.toLowerCase() ?? '';
  if (scheme == 'data' || scheme == 'blob') return true;
  if (!settings.enabledSources.contains(asset.source)) return true;
  final format = formatOf(asset);
  if (format != null && !settings.enabledFormats.contains(format)) return true;
  if (asset.sizeKnown && asset.minSide < settings.minSide) return true;
  return false;
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/features/capture/image_filter_test.dart`

Expected: `All tests passed!`

- [ ] **Step 5: 提交**

```bash
git add lib/features/capture/image_filter.dart test/features/capture/image_filter_test.dart
git commit -m "feat(capture): 过滤规则与筛选设置"
```

---

## Task 7: 两级去重

**Files:**
- Create: `lib/features/capture/deduplicator.dart`
- Test: `test/features/capture/deduplicator_test.dart`

- [ ] **Step 1: 写失败的测试**

`test/features/capture/deduplicator_test.dart`：

```dart
import 'package:download_image/core/model/image_asset.dart';
import 'package:download_image/features/capture/deduplicator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('variantKey', () {
    test('去掉 w / h / width / height / size 查询参数', () {
      expect(variantKey('https://a.com/i.jpg?w=300'), variantKey('https://a.com/i.jpg?w=900'));
      expect(variantKey('https://a.com/i.jpg?width=300'), variantKey('https://a.com/i.jpg'));
      expect(variantKey('https://a.com/i.jpg?size=large'), variantKey('https://a.com/i.jpg'));
    });

    test('保留其他查询参数', () {
      expect(variantKey('https://a.com/i.jpg?token=abc'), isNot(variantKey('https://a.com/i.jpg?token=def')));
      expect(variantKey('https://a.com/i.jpg?w=300&token=abc'), 'https://a.com/i.jpg?token=abc');
    });

    test('编码参数与同名参数不同的 URL 不被误合并', () {
      expect(variantKey('https://a.com/i.jpg?a=b&c=d'), isNot(variantKey('https://a.com/i.jpg?a=b%26c%3Dd')));
      expect(variantKey('https://a.com/i.jpg?token=a&token=b'), isNot(variantKey('https://a.com/i.jpg?token=b')));
    });

    test('无 scheme 时原样返回，不做任何剥离', () {
      expect(variantKey('//a.com/i.jpg?w=300'), '//a.com/i.jpg?w=300');
      expect(variantKey('relative/path.jpg'), 'relative/path.jpg');
    });

    test('去掉 _300x300 / -300x300 路径后缀', () {
      expect(variantKey('https://a.com/pic_300x300.jpg'), 'https://a.com/pic.jpg');
      expect(variantKey('https://a.com/pic-600x600.jpg'), 'https://a.com/pic.jpg');
      expect(variantKey('https://a.com/pic.jpg'), 'https://a.com/pic.jpg');
    });

    test('不误伤正常路径', () {
      expect(variantKey('https://a.com/2024/01/a.jpg'), 'https://a.com/2024/01/a.jpg');
      expect(variantKey('https://a.com/v2-ab_300x300_extra.jpg'), 'https://a.com/v2-ab_300x300_extra.jpg');
    });
  });

  group('deduplicate', () {
    test('一级去重：URL 完全相同合并为一条，尺寸取更大者', () {
      final result = deduplicate(
        const [
          ImageAsset(url: 'https://a.com/i.jpg', width: 300, height: 300),
          ImageAsset(url: 'https://a.com/i.jpg', width: 900, height: 900),
          ImageAsset(url: 'https://a.com/i.jpg', width: 300, height: 300),
        ],
        mergeVariants: false,
      );
      expect(result.length, 1);
      expect(result.single.width, 900);
    });

    test('二级去重：同路径尺寸变体只保留像素最大的一个', () {
      final result = deduplicate(
        const [
          ImageAsset(url: 'https://a.com/i.jpg?w=300', width: 300, height: 300),
          ImageAsset(url: 'https://a.com/i.jpg?w=900', width: 900, height: 900),
          ImageAsset(url: 'https://a.com/i.jpg'),
        ],
        mergeVariants: true,
      );
      expect(result.length, 1);
      expect(result.single.url, 'https://a.com/i.jpg?w=900');
      expect(result.single.width, 900);
    });

    test('二级去重支持 _300x300 后缀', () {
      final result = deduplicate(
        const [
          ImageAsset(url: 'https://a.com/pic_300x300.jpg', width: 300, height: 300),
          ImageAsset(url: 'https://a.com/pic_900x900.jpg', width: 900, height: 900),
        ],
        mergeVariants: true,
      );
      expect(result.length, 1);
      expect(result.single.url, 'https://a.com/pic_900x900.jpg');
    });

    test('尺寸都未知时保留先出现的那条', () {
      final result = deduplicate(
        const [
          ImageAsset(url: 'https://a.com/i.jpg?w=300'),
          ImageAsset(url: 'https://a.com/i.jpg?w=900'),
        ],
        mergeVariants: true,
      );
      expect(result.length, 1);
      expect(result.single.url, 'https://a.com/i.jpg?w=300');
    });

    test('关闭二级去重后尺寸变体都保留', () {
      final result = deduplicate(
        const [
          ImageAsset(url: 'https://a.com/i.jpg?w=300', width: 300, height: 300),
          ImageAsset(url: 'https://a.com/i.jpg?w=900', width: 900, height: 900),
        ],
        mergeVariants: false,
      );
      expect(result.length, 2);
    });

    test('不同路径不被合并', () {
      final result = deduplicate(
        const [
          ImageAsset(url: 'https://a.com/a.jpg', width: 300, height: 300),
          ImageAsset(url: 'https://a.com/b.jpg', width: 300, height: 300),
        ],
        mergeVariants: true,
      );
      expect(result.length, 2);
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/features/capture/deduplicator_test.dart`

Expected: FAIL，`Undefined name 'variantKey'`。

- [ ] **Step 3: 写最小实现**

`lib/features/capture/deduplicator.dart`：

```dart
import '../../core/model/image_asset.dart';

const Set<String> _dimensionParams = {'w', 'h', 'width', 'height', 'size'};

final RegExp _dimensionSuffix = RegExp(r'[_-]\d+x\d+(?=\.|$)');

/// 尺寸变体归组用的 key：去掉尺寸类查询参数与 `_300x300` / `-300x300` 路径后缀。
/// 保留其它查询参数，避免把不同资源误判为同一张图。
/// query 按**原始片段**逐一过滤后原样拼回（不先解码再拼接），因此 `%26`、同名参数等
/// 不同 URL 不会碰撞成同一 key 而被误合并；解析失败或无 scheme 时原样返回；
/// fragment 不参与归组。返回值仅作内部归组键，不保证是合法 URL。
String variantKey(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return url;
  final path = uri.path.replaceAll(_dimensionSuffix, '');
  final query = uri.query
      .split('&')
      .where((segment) => segment.isNotEmpty)
      .where((segment) => !_dimensionParams.contains(segment.split('=').first.toLowerCase()))
      .join('&');
  final buffer = StringBuffer()
    ..write(uri.scheme)
    ..write('://')
    ..write(uri.authority)
    ..write(path);
  if (query.isNotEmpty) {
    buffer
      ..write('?')
      ..write(query);
  }
  return buffer.toString();
}

int _pixelArea(ImageAsset asset) => asset.sizeKnown ? asset.width! * asset.height! : -1;

/// 两级去重（设计文档第 8 节）。
/// 一级：URL 完全相同 → 合并。二级：同 variantKey 的尺寸变体 → 只保留像素最大的一个。
List<ImageAsset> deduplicate(List<ImageAsset> assets, {required bool mergeVariants}) {
  final byUrl = <String, ImageAsset>{};
  for (final asset in assets) {
    final existing = byUrl[asset.url];
    byUrl[asset.url] = existing == null ? asset : existing.merge(asset);
  }
  final merged = byUrl.values.toList();
  if (!mergeVariants) return merged;

  final result = <ImageAsset>[];
  final indexByKey = <String, int>{};
  for (final asset in merged) {
    final key = variantKey(asset.url);
    final index = indexByKey[key];
    if (index == null) {
      indexByKey[key] = result.length;
      result.add(asset);
      continue;
    }
    if (_pixelArea(asset) > _pixelArea(result[index])) {
      result[index] = asset;
    }
  }
  return result;
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/features/capture/deduplicator_test.dart`

Expected: `All tests passed!`

- [ ] **Step 5: 提交**

```bash
git add lib/features/capture/deduplicator.dart test/features/capture/deduplicator_test.dart
git commit -m "feat(capture): 两级去重与尺寸变体归组"
```

---

## Task 8: JS ↔ Dart 桥协议

**Files:**
- Create: `lib/core/bridge/bridge_protocol.dart`
- Test: `test/core/bridge/bridge_protocol_test.dart`

- [ ] **Step 1: 写失败的测试**

`test/core/bridge/bridge_protocol_test.dart`：

```dart
import 'dart:convert';

import 'package:download_image/core/bridge/bridge_protocol.dart';
import 'package:download_image/core/model/image_asset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BridgeMessage.parse', () {
    test('解析 batch（JSON 字符串）', () {
      final raw = jsonEncode({
        'type': 'batch',
        'pageUrl': 'https://a.com/p',
        'assets': [
          {'url': 'https://a.com/a.jpg', 'w': 300, 'h': 200, 'size': 1024, 'mime': 'image/jpeg', 'source': 'img'},
          {'url': 'https://a.com/b.png', 'source': 'cssBackground'},
        ],
      });

      final message = BridgeMessage.parse(raw);
      expect(message, isA<CaptureBatch>());
      final batch = message! as CaptureBatch;
      expect(batch.pageUrl, 'https://a.com/p');
      expect(batch.assets.length, 2);
      expect(batch.assets.first.width, 300);
      expect(batch.assets.last.source, ImageSource.cssBackground);
      expect(batch.assets.last.sizeKnown, isFalse);
    });

    test('解析 batch（已解码的 Map，兼容 callHandler 直传对象）', () {
      final message = BridgeMessage.parse({
        'type': 'batch',
        'pageUrl': 'https://a.com/p',
        'assets': <Object?>[],
      });
      expect((message! as CaptureBatch).assets, isEmpty);
    });

    test('解析 scan', () {
      final message = BridgeMessage.parse(jsonEncode({
        'type': 'scan',
        'state': 'progress',
        'pageUrl': 'https://a.com/p',
        'screen': 12,
        'maxScreens': 40,
        'found': 30,
      }));
      final scan = message! as ScanProgress;
      expect(scan.state, ScanState.progress);
      expect(scan.screen, 12);
      expect(scan.maxScreens, 40);
      expect(scan.found, 30);
    });

    test('解析 blob（正常分块与错误分块）', () {
      final ok = BridgeMessage.parse(jsonEncode({
        'type': 'blob',
        'id': 'dl-1',
        'seq': 2,
        'data': 'aGVsbG8=',
        'last': false,
        'mime': 'image/png',
      }))! as BlobChunk;
      expect(ok.id, 'dl-1');
      expect(ok.seq, 2);
      expect(ok.data, 'aGVsbG8=');
      expect(ok.last, isFalse);
      expect(ok.mime, 'image/png');
      expect(ok.error, isNull);

      final failed = BridgeMessage.parse(jsonEncode({
        'type': 'blob',
        'id': 'dl-2',
        'seq': 0,
        'data': '',
        'last': true,
        'error': 'HTTP 403',
      }))! as BlobChunk;
      expect(failed.error, 'HTTP 403');
    });

    test('未知类型、坏 JSON、非对象一律返回 null 而不抛异常', () {
      expect(BridgeMessage.parse(jsonEncode({'type': 'nope'})), isNull);
      expect(BridgeMessage.parse('{ this is not json'), isNull);
      expect(BridgeMessage.parse('42'), isNull);
      expect(BridgeMessage.parse(null), isNull);
      expect(BridgeMessage.parse(<Object?>[]), isNull);
    });

    test('scan 状态未知时回退为 done', () {
      final scan = BridgeMessage.parse(jsonEncode({'type': 'scan', 'state': 'weird'}))! as ScanProgress;
      expect(scan.state, ScanState.done);
      expect(scan.maxScreens, 40, reason: '缺省上限为 40 屏');
    });

    test('单条 asset 字段类型不对只跳过该张，不丢整批', () {
      final batch = BridgeMessage.parse(jsonEncode({
        'type': 'batch',
        'pageUrl': 'https://a.com/p',
        'assets': [
          {'url': 'https://a.com/good.jpg', 'w': 300, 'h': 200},
          {'url': 'https://a.com/dirty.jpg', 'w': '300'},
          {'w': 5},
          'not-a-map',
        ],
      }))! as CaptureBatch;
      expect(batch.assets.length, 1);
      expect(batch.assets.single.url, 'https://a.com/good.jpg');
    });

    test('scan 的 state 非字符串时回退为 done 而不丢弃整条', () {
      final scan = BridgeMessage.parse(jsonEncode({'type': 'scan', 'state': 5}))! as ScanProgress;
      expect(scan.state, ScanState.done);
    });
  });

  test('kBlobChunkBytes 为 512KB', () {
    expect(kBlobChunkBytes, 512 * 1024);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/core/bridge/bridge_protocol_test.dart`

Expected: FAIL，`Undefined name 'BridgeMessage'`。

- [ ] **Step 3: 写最小实现**

`lib/core/bridge/bridge_protocol.dart`：

```dart
import 'dart:convert';

import '../model/image_asset.dart';

/// JS 侧注册的 handler 名，抓取与下载共用这一个通道。
const String kBridgeHandlerName = 'imgcat';

/// blob 分块大小：512KB（分块是为了避免大图 base64 全量驻留内存）。
const int kBlobChunkBytes = 512 * 1024;

/// 扫描上限（设计文档第 6 节）：到达任一上限即停止。
const int kMaxScanScreens = 40;
const Duration kScanTimeout = Duration(seconds: 60);

enum ScanState { start, progress, done, limit, aborted }

/// JS → Dart 的消息。解析失败一律返回 null，不向上抛异常。
sealed class BridgeMessage {
  const BridgeMessage();

  static BridgeMessage? parse(Object? raw) {
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! Map) return null;
      final map = decoded.map((key, value) => MapEntry(key.toString(), value));
      switch (map['type']) {
        case 'batch':
          return CaptureBatch.fromMap(map);
        case 'scan':
          return ScanProgress.fromMap(map);
        case 'blob':
          return BlobChunk.fromMap(map);
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }
}

/// 增量推送的一批图片：每发现一批就推一次，不等扫完。
class CaptureBatch extends BridgeMessage {
  const CaptureBatch({required this.pageUrl, required this.assets});

  final String pageUrl;
  final List<ImageAsset> assets;

  factory CaptureBatch.fromMap(Map<String, Object?> map) {
    final rawAssets = map['assets'];
    final assets = <ImageAsset>[];
    if (rawAssets is List) {
      for (final item in rawAssets) {
        if (item is Map) {
          try {
            final json = item.map((key, value) => MapEntry(key.toString(), value));
            if (json['url'] is String) assets.add(ImageAsset.fromJson(json));
          } catch (_) {
            // 单条脏数据只跳过该张，不能拖垮整批增量推送。
          }
        }
      }
    }
    return CaptureBatch(pageUrl: map['pageUrl'] as String? ?? '', assets: assets);
  }
}

/// 自动扫整页的进度。
class ScanProgress extends BridgeMessage {
  const ScanProgress({
    required this.state,
    this.pageUrl = '',
    this.screen = 0,
    this.maxScreens = kMaxScanScreens,
    this.found = 0,
  });

  final ScanState state;
  final String pageUrl;

  /// 已滚动的屏数。
  final int screen;
  final int maxScreens;
  final int found;

  bool get isRunning => state == ScanState.start || state == ScanState.progress;

  factory ScanProgress.fromMap(Map<String, Object?> map) {
    // 不硬转字符串：非字符串的 state 也走「未知 → done」回退，而不是丢弃整条消息。
    final name = map['state'];
    return ScanProgress(
      state: ScanState.values.firstWhere(
        (value) => value.name == name,
        orElse: () => ScanState.done,
      ),
      pageUrl: map['pageUrl'] as String? ?? '',
      screen: (map['screen'] as num?)?.toInt() ?? 0,
      maxScreens: (map['maxScreens'] as num?)?.toInt() ?? kMaxScanScreens,
      found: (map['found'] as num?)?.toInt() ?? 0,
    );
  }
}

/// blob 通道的一个分块。[error] 非空表示这一路失败，可以降级。
class BlobChunk extends BridgeMessage {
  const BlobChunk({
    required this.id,
    required this.seq,
    required this.data,
    required this.last,
    this.mime,
    this.error,
  });

  final String id;
  final int seq;
  final String data;
  final bool last;
  final String? mime;
  final String? error;

  factory BlobChunk.fromMap(Map<String, Object?> map) {
    return BlobChunk(
      id: map['id'] as String? ?? '',
      seq: (map['seq'] as num?)?.toInt() ?? 0,
      data: map['data'] as String? ?? '',
      last: map['last'] == true,
      mime: map['mime'] as String?,
      error: map['error'] as String?,
    );
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/core/bridge/bridge_protocol_test.dart`

Expected: `All tests passed!`

- [ ] **Step 5: 提交**

```bash
git add lib/core/bridge/bridge_protocol.dart test/core/bridge/bridge_protocol_test.dart
git commit -m "feat(bridge): JS-Dart 桥协议定义与解析"
```

---

## Task 9: 注入 JS 抓取脚本

**Files:**
- Create: `lib/features/capture/capture_script.dart`

JS 无法用 `flutter test` 单测，所以本任务只写脚本 + 语法自检；行为断言在 Task 18 的 `integration_test` 里做。

- [ ] **Step 1: 写脚本**

`lib/features/capture/capture_script.dart`：

```dart
/// 注入到每个页面的抓取脚本。设计文档第 6 节。
///
/// 三路并行汇入同一个聚合器：
/// 1. PerformanceObserver（resource）→ 覆盖 JS 动态加载的图片；
/// 2. MutationObserver（childList / src / srcset / style / class）→ 覆盖懒加载与背景图；
/// 3. 全量 DOM 扫描 → img.currentSrc、srcset 最大候选、CSS 背景图、picture>source、svg>image。
///
/// 只上报 http/https URL；data: 与 blob: 不上报（不可下载）。
const String kCaptureScript = r'''
(function () {
  if (window.__imgcat) return;

  var SOURCE_RANK = { dynamic: 0, cssBackground: 1, srcset: 2, img: 3 };
  var IMG_EXT = /\.(jpe?g|png|gif|webp|svg|avif|bmp|ico)(\?|#|$)/i;
  var HANDLER = 'imgcat';

  var seen = Object.create(null);
  var pending = Object.create(null);
  var pendingCount = 0;
  var cssPassNeeded = true;
  var rescanTimer = null;
  var running = false;
  var aborted = false;

  // ---------- 桥就绪管理：AT_DOCUMENT_START 注入时 bridge 还没好，先排队 ----------
  var ready = false;
  var outbox = [];

  function bridgeAvailable() {
    return !!(window.flutter_inappwebview && window.flutter_inappwebview.callHandler);
  }

  function post(payload) {
    if (!ready) { outbox.push(payload); return; }
    try {
      window.flutter_inappwebview.callHandler(HANDLER, JSON.stringify(payload));
    } catch (e) { /* 桥断了就丢弃这一批，不阻塞页面 */ }
  }

  function markReady() {
    if (ready || !bridgeAvailable()) return;
    while (outbox.length) {
      try {
        window.flutter_inappwebview.callHandler(HANDLER, JSON.stringify(outbox[0]));
      } catch (e) { return; } // 发送失败就把队首留在队列里，下个 tick 再试
      outbox.shift();
    }
    ready = true;
  }

  window.addEventListener('flutterInAppWebViewPlatformReady', markReady);
  // 轮询必须持续到 ready 为真：仅凭「桥对象存在」就停表，会在
  // 「对象存在但 callHandler 尚不可用、且就绪事件被错过」时让 outbox 永久卡死。
  var readyTimer = setInterval(function () {
    if (ready) { clearInterval(readyTimer); return; }
    markReady();
  }, 100);
  setTimeout(function () { clearInterval(readyTimer); }, 10000);

  function waitForBridge(timeoutMs) {
    return new Promise(function (resolve, reject) {
      var start = Date.now();
      (function tick() {
        if (ready) return resolve();
        if (Date.now() - start > timeoutMs) return reject(new Error('bridge-timeout'));
        setTimeout(tick, 100);
      })();
    });
  }

  // ---------- URL 归一化 ----------
  function normalize(u) {
    if (!u) return null;
    var s = String(u).trim();
    if (!s || s.indexOf('data:') === 0 || s.indexOf('blob:') === 0) return null;
    try {
      var abs = new URL(s, location.href).href;
      if (abs.indexOf('http://') !== 0 && abs.indexOf('https://') !== 0) return null;
      return abs;
    } catch (e) { return null; }
  }

  // ---------- 聚合 ----------
  function collect(u, source, w, h, size, mime) {
    var url = normalize(u);
    if (!url) return;
    var entry = seen[url];
    if (entry) {
      // 只有信息真的变了才重新入 pending；否则每轮扫描都会把全量快照重推一遍桥。
      var changed = false;
      if (SOURCE_RANK[source] > SOURCE_RANK[entry.source]) { entry.source = source; changed = true; }
      if (w != null && h != null && (entry.w == null || entry.w < w)) { entry.w = w; entry.h = h; changed = true; }
      if (size != null && entry.size == null) { entry.size = size; changed = true; }
      if (mime != null && entry.mime == null) { entry.mime = mime; changed = true; }
      if (!changed) return;
    } else {
      seen[url] = { url: url, source: source, w: w, h: h, size: size, mime: mime };
    }
    if (!pending[url]) { pending[url] = true; pendingCount++; }
  }

  function countAssets() {
    var n = 0;
    for (var k in seen) n++;
    return n;
  }

  function flush() {
    if (pendingCount === 0) return;
    var assets = [];
    for (var url in pending) {
      delete pending[url];
      var e = seen[url];
      assets.push({ url: e.url, w: e.w, h: e.h, size: e.size, mime: e.mime, source: e.source });
    }
    pendingCount = 0;
    post({ type: 'batch', pageUrl: location.href, assets: assets });
  }

  // ---------- 三路采集源 ----------
  function urlsInBackgroundImage(value) {
    var out = [];
    if (!value || value === 'none') return out;
    var re = /url\((['"]?)([^'")]+)\1\)/g;
    var m;
    while ((m = re.exec(value)) !== null) { if (m[2]) out.push(m[2]); }
    return out;
  }

  function pickFromSrcset(srcset) {
    if (!srcset) return null;
    var parts = String(srcset).split(',');
    var best = null;
    var bestW = -1;
    for (var i = 0; i < parts.length; i++) {
      var fields = parts[i].trim().split(/\s+/);
      if (!fields[0]) continue;
      var w = -1;
      if (fields.length > 1) {
        var d = fields[1].toLowerCase();
        var body = d.substring(0, d.length - 1);
        if (d.charAt(d.length - 1) === 'w') w = parseInt(body, 10);
        else if (d.charAt(d.length - 1) === 'x') w = Math.round(parseFloat(body) * 1000);
      }
      if (isNaN(w)) w = -1;
      // 并列时取先出现的，与 lib/features/capture/srcset.dart 的 pickLargest 保持一致。
      if (best === null || w > bestW) {
        bestW = w;
        best = { url: fields[0], width: w < 0 ? null : w };
      }
    }
    return best;
  }

  /// includeCssPass 为 false 时跳过 CSS 背景图全量遍历（代价高，只在必要时跑）。
  function scanImages(includeCssPass) {
    var imgs = document.images;
    for (var i = 0; i < imgs.length; i++) {
      var img = imgs[i];
      var best = pickFromSrcset(img.getAttribute('srcset'));
      if (best) {
        collect(best.url, 'srcset', best.width, null, null, null);
      } else {
        collect(img.currentSrc || img.src, 'img', img.naturalWidth || null, img.naturalHeight || null, null, null);
      }
    }
    var media = document.querySelectorAll('picture source, svg image');
    for (var s = 0; s < media.length; s++) {
      var el = media[s];
      var best2 = pickFromSrcset(el.getAttribute('srcset'));
      if (best2) collect(best2.url, 'srcset', best2.width, null, null, null);
      var href = el.getAttribute('href') || el.getAttribute('xlink:href');
      if (href) collect(href, 'img', el.naturalWidth || null, el.naturalHeight || null, null, null);
    }
    if (!includeCssPass) return;
    var all = document.querySelectorAll('*');
    for (var j = 0; j < all.length; j++) {
      var bg = getComputedStyle(all[j]).backgroundImage;
      if (!bg || bg === 'none') continue;
      var urls = urlsInBackgroundImage(bg);
      for (var k = 0; k < urls.length; k++) collect(urls[k], 'cssBackground', null, null, null, null);
    }
  }

  function scheduleRescan(includeCssPass) {
    if (includeCssPass) cssPassNeeded = true;
    if (rescanTimer) return;
    rescanTimer = setTimeout(function () {
      rescanTimer = null;
      var withCss = cssPassNeeded;
      cssPassNeeded = false;
      scanImages(withCss);
      flush();
    }, 300);
  }

  // 1) PerformanceObserver：覆盖 JS 动态加载的图片
  try {
    var po = new PerformanceObserver(function (list) {
      var entries = list.getEntries();
      for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        var isImageRequest = e.initiatorType === 'img' || IMG_EXT.test(e.name);
        if (!isImageRequest) continue;
        collect(e.name, 'dynamic', null, null, e.transferSize || e.decodedBodySize || null, null);
      }
      scheduleRescan(false);
    });
    po.observe({ type: 'resource', buffered: true });
  } catch (e) { /* 老引擎不支持 resource timing 时降级为纯 DOM 扫描 */ }

  // 2) MutationObserver：覆盖懒加载与背景图切换
  try {
    var mo = new MutationObserver(function (mutations) {
      for (var i = 0; i < mutations.length; i++) {
        var m = mutations[i];
        if (m.type === 'attributes' || (m.addedNodes && m.addedNodes.length)) {
          scheduleRescan(true);
          return;
        }
      }
    });
    mo.observe(document.documentElement, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ['src', 'srcset', 'style', 'class', 'data-src']
    });
  } catch (e) { /* 忽略 */ }

  // ---------- 自动扫整页 ----------
  function waitForImages(timeoutMs) {
    return new Promise(function (resolve) {
      var start = Date.now();
      (function tick() {
        var pendingImgs = 0;
        for (var i = 0; i < document.images.length; i++) {
          if (!document.images[i].complete) pendingImgs++;
        }
        if (pendingImgs === 0 || Date.now() - start > timeoutMs) return resolve();
        setTimeout(tick, 50);
      })();
    });
  }

  function isAtBottom() {
    var doc = document.documentElement;
    return window.scrollY + window.innerHeight >= doc.scrollHeight - 4;
  }

  async function scan(opts) {
    opts = opts || {};
    if (running) return { ok: false, reason: 'already-running' };
    running = true;
    aborted = false;
    var maxScreens = opts.maxScreens || 40;
    var timeoutMs = opts.timeoutMs || 60000;
    var deadline = Date.now() + timeoutMs;
    var pageUrl = location.href;
    var startY = window.scrollY;
    var screen = 0;
    var limited = false;

    post({ type: 'scan', state: 'start', pageUrl: pageUrl, screen: 0, maxScreens: maxScreens, found: countAssets() });
    scanImages(true);
    flush();

    try {
      for (screen = 1; screen <= maxScreens; screen++) {
        if (aborted) {
          post({ type: 'scan', state: 'aborted', pageUrl: pageUrl, screen: screen - 1, maxScreens: maxScreens, found: countAssets() });
          return { ok: true, aborted: true };
        }
        window.scrollBy(0, Math.max(1, Math.floor(window.innerHeight * 0.9)));
        await waitForImages(600);
        scanImages(screen === 1);
        flush();
        post({ type: 'scan', state: 'progress', pageUrl: pageUrl, screen: screen, maxScreens: maxScreens, found: countAssets() });
        if (Date.now() >= deadline) { limited = true; break; }
        if (isAtBottom()) break;
      }
      if (screen > maxScreens) limited = true;
    } finally {
      aborted = false;
      running = false;
      window.scrollTo(0, startY);
    }

    scanImages(true);
    flush();
    post({
      type: 'scan',
      state: limited ? 'limit' : 'done',
      pageUrl: pageUrl,
      screen: Math.min(screen, maxScreens),
      maxScreens: maxScreens,
      found: countAssets()
    });
    return { ok: true, limited: limited };
  }

  // ---------- 下载：页面内 fetch 取 blob，512KB 分块回传 ----------
  function bytesToBase64(bytes) {
    var step = 0x8000;
    var out = '';
    for (var i = 0; i < bytes.length; i += step) {
      out += String.fromCharCode.apply(null, bytes.subarray(i, i + step));
    }
    return btoa(out);
  }

  async function fetchAsBase64(opts) {
    opts = opts || {};
    var id = opts.id;
    var chunkSize = opts.chunkSize || 524288;
    try {
      await waitForBridge(5000);
      var res = await fetch(opts.url, { credentials: 'include', referrer: location.href });
      if (!res.ok) throw new Error('HTTP ' + res.status);
      var bytes = new Uint8Array(await res.arrayBuffer());
      var mime = res.headers.get('content-type') || null;
      if (bytes.length === 0) {
        await window.flutter_inappwebview.callHandler(HANDLER, JSON.stringify({
          type: 'blob', id: id, seq: 0, data: '', last: true, mime: mime
        }));
        return { ok: true, length: 0 };
      }
      var seq = 0;
      for (var off = 0; off < bytes.length; off += chunkSize) {
        var slice = bytes.subarray(off, Math.min(off + chunkSize, bytes.length));
        var isLast = off + chunkSize >= bytes.length;
        await window.flutter_inappwebview.callHandler(HANDLER, JSON.stringify({
          type: 'blob', id: id, seq: seq++, data: bytesToBase64(slice), last: isLast, mime: mime
        }));
      }
      return { ok: true, length: bytes.length };
    } catch (e) {
      post({ type: 'blob', id: id, seq: 0, data: '', last: true, error: String((e && e.message) || e) });
      return { ok: false };
    }
  }

  window.__imgcat = {
    scan: scan,
    abort: function () { aborted = true; return { ok: true }; },
    fetchAsBase64: fetchAsBase64,
    rescan: function () { scanImages(true); flush(); return { ok: true, count: countAssets() }; },
    assets: function () { var out = []; for (var k in seen) out.push(k); return out; }
  };

  scheduleRescan(true);
})();
''';
```

要点说明（写代码时不要改掉这几点）：
- `window.__imgcat` 存在性检查防重复注入；user script 每次导航都会重新注入。
- AT_DOCUMENT_START 时 `window.flutter_inappwebview` 还没就绪，必须靠 `outbox` 排队 + `flutterInAppWebViewPlatformReady` 事件 + 轮询兜底。
- `document.images.length` 的 `complete` 等待有 600ms 上限，避免死等。
- 扫描循环用 `scrollBy`（不会因为页面变高而倒退），上限 40 屏 / 60 秒，先到者生效。
- 只有 `img.currentSrc` 拿到的是浏览器实际使用的候选，所以带 `srcset` 的 `<img>` 按设计文档取「最大候选」并标记为 `srcset`，其尺寸记为未知（描述符宽度不作为宽高）。

- [ ] **Step 2: 语法自检（用 node 解析这段 JS）**

Run（把脚本抽出来交给 Node 做语法检查；只要 `node --check` 通过即可）:

```bash
/Users/ling/fvm/versions/3.47.4/bin/dart run tool/check_js_syntax.dart
```

若仓库里还没有 `tool/check_js_syntax.dart`，本步先用下面这条等价命令代替（从 Dart 源里抽出脚本文本再校验）：

```bash
/Users/ling/fvm/versions/3.47.4/bin/dart -e "import 'dart:io'; import 'package:download_image/features/capture/capture_script.dart'; void main() { File('/tmp/imgcat_capture.js').writeAsStringSync(kCaptureScript); }" && node --check /tmp/imgcat_capture.js
```

Expected: 无输出（`node --check` 通过时静默退出）。若报 `SyntaxError`，修脚本直到通过。

- [ ] **Step 3: 确认脚本已被静态分析接受**

Run:

```bash
/Users/ling/fvm/versions/3.47.4/bin/flutter analyze
```

Expected: `No issues found!`

- [ ] **Step 4: 提交**

```bash
git add lib/features/capture/capture_script.dart
git commit -m "feat(capture): 注入式抓取脚本（PerformanceObserver + MutationObserver + 全量扫描 + blob 分块回传）"
```

---

## Task 10: CaptureController 聚合器

**Files:**
- Create: `lib/features/capture/capture_controller.dart`
- Test: `test/features/capture/capture_controller_test.dart`

- [ ] **Step 1: 写失败的测试**

`test/features/capture/capture_controller_test.dart`：

```dart
import 'dart:convert';

import 'package:download_image/core/bridge/bridge_protocol.dart';
import 'package:download_image/core/model/image_asset.dart';
import 'package:download_image/features/capture/capture_controller.dart';
import 'package:flutter_test/flutter_test.dart';

String _batch(List<Map<String, Object?>> assets, {String pageUrl = 'https://a.com/p'}) {
  return jsonEncode({'type': 'batch', 'pageUrl': pageUrl, 'assets': assets});
}

void main() {
  test('batch 增量聚合，同 URL 合并为一条', () {
    final controller = CaptureController();
    controller.accept(BridgeMessage.parse(_batch([
      {'url': 'https://a.com/a.jpg', 'w': 300, 'h': 300, 'source': 'img'},
    ]))!);
    expect(controller.rawAssets.length, 1);

    controller.accept(BridgeMessage.parse(_batch([
      {'url': 'https://a.com/a.jpg', 'w': 900, 'h': 900, 'source': 'img'},
      {'url': 'https://a.com/b.png', 'w': 100, 'h': 100, 'source': 'img'},
    ]))!);

    expect(controller.rawAssets.length, 2);
    expect(controller.rawAssets.first.width, 900);
    expect(controller.pageUrl, 'https://a.com/p');
    expect(controller.notifyCount, greaterThanOrEqualTo(2));
  });

  test('visibleAssets 应用过滤与去重', () {
    final controller = CaptureController();
    controller.accept(BridgeMessage.parse(_batch([
      {'url': 'https://a.com/small.jpg', 'w': 10, 'h': 10, 'source': 'img'},
      {'url': 'https://a.com/big.jpg?w=300', 'w': 300, 'h': 300, 'source': 'img'},
      {'url': 'https://a.com/big.jpg?w=900', 'w': 900, 'h': 900, 'source': 'img'},
      {'url': 'data:image/png;base64,AAAA', 'source': 'img'},
    ]))!);

    expect(controller.rawAssets.length, 4);
    final visible = controller.visibleAssets;
    expect(visible.length, 1);
    expect(visible.single.url, 'https://a.com/big.jpg?w=900');
  });

  test('调整最小边阈值即时生效', () {
    final controller = CaptureController();
    controller.accept(BridgeMessage.parse(_batch([
      {'url': 'https://a.com/a.jpg', 'w': 100, 'h': 100, 'source': 'img'},
    ]))!);
    expect(controller.visibleAssets.length, 1);

    controller.setMinSide(200);
    expect(controller.filter.minSide, 200);
    expect(controller.visibleAssets, isEmpty);
  });

  test('切换格式 chip 即时生效', () {
    final controller = CaptureController();
    controller.accept(BridgeMessage.parse(_batch([
      {'url': 'https://a.com/a.jpg', 'w': 100, 'h': 100, 'source': 'img'},
      {'url': 'https://a.com/b.png', 'w': 100, 'h': 100, 'source': 'img'},
    ]))!);
    expect(controller.visibleAssets.length, 2);

    controller.toggleFormat('png');
    expect(controller.visibleAssets.map((e) => e.url), ['https://a.com/a.jpg']);
  });

  test('切换来源 chip 即时生效', () {
    final controller = CaptureController();
    controller.accept(BridgeMessage.parse(_batch([
      {'url': 'https://a.com/a.jpg', 'w': 100, 'h': 100, 'source': 'img'},
      {'url': 'https://a.com/bg.jpg', 'w': 100, 'h': 100, 'source': 'cssBackground'},
    ]))!);

    controller.setSources({ImageSource.cssBackground});
    expect(controller.visibleAssets.map((e) => e.url), ['https://a.com/bg.jpg']);
  });

  test('关闭二级去重后尺寸变体都保留', () {
    final controller = CaptureController();
    controller.accept(BridgeMessage.parse(_batch([
      {'url': 'https://a.com/big.jpg?w=300', 'w': 300, 'h': 300, 'source': 'img'},
      {'url': 'https://a.com/big.jpg?w=900', 'w': 900, 'h': 900, 'source': 'img'},
    ]))!);
    expect(controller.visibleAssets.length, 1);

    controller.setMergeVariants(false);
    expect(controller.visibleAssets.length, 2);
  });

  test('scan 进度写入 scan 字段，不是 running 状态', () {
    final controller = CaptureController();
    controller.accept(BridgeMessage.parse(jsonEncode({
      'type': 'scan', 'state': 'progress', 'screen': 5, 'maxScreens': 40, 'found': 12,
    }))!);
    expect(controller.scan?.state, ScanState.progress);
    expect(controller.scan?.screen, 5);

    controller.accept(BridgeMessage.parse(jsonEncode({
      'type': 'scan', 'state': 'limit', 'screen': 40, 'maxScreens': 40, 'found': 90,
    }))!);
    expect(controller.scanReachedLimit, isTrue);

    controller.accept(BridgeMessage.parse(jsonEncode({'type': 'scan', 'state': 'start'}))!);
    expect(controller.scanReachedLimit, isFalse, reason: '新一次扫描要清掉上次的上限提示');
  });

  test('选中态流转：单选、全选可见项、清空、切换页面时清空', () {
    final controller = CaptureController();
    controller.accept(BridgeMessage.parse(_batch([
      {'url': 'https://a.com/a.jpg', 'w': 100, 'h': 100, 'source': 'img'},
      {'url': 'https://a.com/b.jpg', 'w': 100, 'h': 100, 'source': 'img'},
    ]))!);

    controller.toggleSelection('https://a.com/a.jpg');
    expect(controller.selectedUrls, {'https://a.com/a.jpg'});
    controller.toggleSelection('https://a.com/a.jpg');
    expect(controller.selectedUrls, isEmpty);

    controller.selectAllVisible();
    expect(controller.selectedUrls.length, 2);
    controller.clearSelection();
    expect(controller.selectedUrls, isEmpty);

    controller.toggleSelection('https://a.com/a.jpg');
    controller.clear();
    expect(controller.rawAssets, isEmpty);
    expect(controller.selectedUrls, isEmpty);
    expect(controller.pageUrl, isNull);
  });

  test('selectedAssets 只返回还可见的选中项', () {
    final controller = CaptureController();
    controller.accept(BridgeMessage.parse(_batch([
      {'url': 'https://a.com/a.jpg', 'w': 100, 'h': 100, 'source': 'img'},
    ]))!);
    controller.toggleSelection('https://a.com/a.jpg');
    expect(controller.selectedAssets.length, 1);

    controller.setMinSide(500);
    expect(controller.selectedAssets, isEmpty);
    expect(controller.selectedUrls.length, 1, reason: '选中态不因筛选变化被隐式清除')
        ;
  });

  test('isScanning 跟随 scan 状态起止', () {
    final controller = CaptureController();
    expect(controller.isScanning, isFalse, reason: '未开始扫描时不显示进度条');

    controller.accept(BridgeMessage.parse(jsonEncode({'type': 'scan', 'state': 'start'}))!);
    expect(controller.isScanning, isTrue);

    controller.accept(BridgeMessage.parse(jsonEncode({
      'type': 'scan', 'state': 'progress', 'screen': 3,
    }))!);
    expect(controller.isScanning, isTrue);

    controller.accept(BridgeMessage.parse(jsonEncode({'type': 'scan', 'state': 'aborted'}))!);
    expect(controller.isScanning, isFalse);
  });

  test('切换页面保留列表时只复位扫描状态', () {
    final controller = CaptureController();
    controller.accept(BridgeMessage.parse(_batch([
      {'url': 'https://a.com/a.jpg', 'w': 100, 'h': 100, 'source': 'img'},
    ]))!);
    controller.toggleSelection('https://a.com/a.jpg');
    controller.accept(BridgeMessage.parse(jsonEncode({
      'type': 'scan', 'state': 'limit', 'screen': 40, 'maxScreens': 40, 'found': 1,
    }))!);

    controller.keepAssetsForNewPage('https://b.com/p');

    expect(controller.pageUrl, 'https://b.com/p');
    expect(controller.rawAssets.length, 1, reason: '保留已抓列表');
    expect(controller.selectedUrls, {'https://a.com/a.jpg'}, reason: '选中态一并保留');
    expect(controller.scan, isNull);
    expect(controller.isScanning, isFalse);
    expect(controller.scanReachedLimit, isFalse, reason: '新页面不能沿用上一页的上限提示');
  });
}
```

Task 11 接线时必须调用 `keepAssetsForNewPage`：页面跳转且用户选择「保留」时，它是唯一能复位扫描态（否则扫描条卡在上一页、且新页因 `isScanning` 为真而不再自动扫描）的出口。

- [ ] **Step 2: 运行测试确认失败**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/features/capture/capture_controller_test.dart`

Expected: FAIL，`Undefined name 'CaptureController'`。

- [ ] **Step 3: 写最小实现**

`lib/features/capture/capture_controller.dart`：

```dart
import 'package:flutter/foundation.dart';

import '../../core/bridge/bridge_protocol.dart';
import '../../core/model/image_asset.dart';
import 'deduplicator.dart';
import 'image_filter.dart';

/// 抓取结果聚合器：把桥消息变成可渲染的列表。
///
/// 选中态也放在这里：它和列表数据同源，单独再开一个控制器没有收益（YAGNI）。
class CaptureController extends ChangeNotifier {
  final Map<String, ImageAsset> _byUrl = <String, ImageAsset>{};

  FilterSettings _filter = const FilterSettings();
  ScanProgress? _scan;
  bool _reachedLimit = false;
  String? _pageUrl;
  final Set<String> _selected = <String>{};

  int notifyCount = 0;

  @override
  void notifyListeners() {
    notifyCount++;
    super.notifyListeners();
  }

  List<ImageAsset> get rawAssets => List.unmodifiable(_byUrl.values);

  int get rawCount => _byUrl.length;

  FilterSettings get filter => _filter;

  ScanProgress? get scan => _scan;

  /// 上一次扫描是否撞到 40 屏 / 60 秒上限。
  bool get scanReachedLimit => _reachedLimit;

  bool get isScanning => _scan?.isRunning ?? false;

  /// 结果所属页面 URL，用于「已切换页面」判断。
  String? get pageUrl => _pageUrl;

  Set<String> get selectedUrls => Set.unmodifiable(_selected);

  /// 应用筛选 + 两级去重后的列表。顺序即发现顺序。
  List<ImageAsset> get visibleAssets {
    final kept = _byUrl.values.where((asset) => !isFilteredOut(asset, _filter)).toList();
    return deduplicate(kept, mergeVariants: _filter.mergeVariants);
  }

  /// 选中且当前仍然可见的图片，下载只处理这些。
  List<ImageAsset> get selectedAssets {
    final selected = visibleAssets.where((asset) => _selected.contains(asset.url)).toList();
    return selected;
  }

  void accept(BridgeMessage message) {
    switch (message) {
      case CaptureBatch batch:
        if (batch.pageUrl.isNotEmpty) _pageUrl = batch.pageUrl;
        for (final asset in batch.assets) {
          final existing = _byUrl[asset.url];
          _byUrl[asset.url] = existing == null ? asset : existing.merge(asset);
        }
        notifyListeners();
      case ScanProgress progress:
        if (progress.pageUrl.isNotEmpty) _pageUrl = progress.pageUrl;
        if (progress.state == ScanState.start) _reachedLimit = false;
        if (progress.state == ScanState.limit) _reachedLimit = true;
        _scan = progress;
        notifyListeners();
      case BlobChunk():
        // blob 分块由 DownloadController 处理，聚合器不关心。
        break;
    }
  }

  void setMinSide(int value) {
    _filter = _filter.copyWith(minSide: value);
    notifyListeners();
  }

  void toggleFormat(String format) {
    final formats = Set<String>.from(_filter.enabledFormats);
    if (!formats.remove(format)) formats.add(format);
    _filter = _filter.copyWith(enabledFormats: formats);
    notifyListeners();
  }

  void setMergeVariants(bool value) {
    _filter = _filter.copyWith(mergeVariants: value);
    notifyListeners();
  }

  void setSources(Set<ImageSource> sources) {
    _filter = _filter.copyWith(enabledSources: sources);
    notifyListeners();
  }

  void toggleSource(ImageSource source) {
    final sources = Set<ImageSource>.from(_filter.enabledSources);
    if (!sources.remove(source)) sources.add(source);
    _filter = _filter.copyWith(enabledSources: sources);
    notifyListeners();
  }

  void toggleSelection(String url) {
    if (!_selected.remove(url)) _selected.add(url);
    notifyListeners();
  }

  void selectAllVisible() {
    _selected
      ..clear()
      ..addAll(visibleAssets.map((asset) => asset.url));
    notifyListeners();
  }

  void clearSelection() {
    _selected.clear();
    notifyListeners();
  }

  /// 清空列表与选中态（切换页面时用户选择「清空」）。
  void clear() {
    _byUrl.clear();
    _selected.clear();
    _scan = null;
    _reachedLimit = false;
    _pageUrl = null;
    notifyListeners();
  }

  /// 只重置扫描状态，保留已抓列表（页面跳转时用户选择「保留」）。
  void keepAssetsForNewPage(String newPageUrl) {
    _pageUrl = newPageUrl;
    _scan = null;
    _reachedLimit = false;
    notifyListeners();
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/features/capture/capture_controller_test.dart`

Expected: `All tests passed!`

- [ ] **Step 5: 提交**

```bash
git add lib/features/capture/capture_controller.dart test/features/capture/capture_controller_test.dart
git commit -m "feat(capture): 抓取结果聚合控制器（列表/筛选/选中/扫描状态）"
```

---

## Task 11: BrowserPage 正式实现

**Files:**
- Modify: `lib/features/browser/browser_page.dart`（整体替换 Task 2 的临时版本）
- Create: `lib/features/browser/browser_controller.dart`、`lib/features/browser/webview_js_channel.dart`、`lib/core/bridge/js_channel.dart`

- [ ] **Step 1: 先写 JsChannel 抽象（下载模块依赖它，不依赖 WebView）**

`lib/core/bridge/js_channel.dart`：

```dart
/// 调用页面内 `window.__imgcat.<function>(<args>)` 的统一入口。
/// 抽象出来是为了让 download 模块不 import flutter_inappwebview，从而可单测。
abstract class JsChannel {
  Future<void> call(String function, Map<String, Object?> args);
}

/// WebView 就绪前为空壳，BrowserPage 创建好 WebView 后 attach。
class JsChannelHolder implements JsChannel {
  JsChannel? _inner;

  void attach(JsChannel channel) => _inner = channel;

  void detach() => _inner = null;

  bool get isReady => _inner != null;

  @override
  Future<void> call(String function, Map<String, Object?> args) async {
    final inner = _inner;
    if (inner == null) {
      throw StateError('WebView 尚未就绪，无法调用 $function');
    }
    await inner.call(function, args);
  }
}
```

- [ ] **Step 2: 写真实实现与导航控制器**

`lib/features/browser/webview_js_channel.dart`：

```dart
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/bridge/js_channel.dart';

class WebViewJsChannel implements JsChannel {
  WebViewJsChannel(this.controller);

  final InAppWebViewController controller;

  @override
  Future<void> call(String function, Map<String, Object?> args) async {
    final payload = jsonEncode(args);
    final source = 'window.__imgcat && window.__imgcat.$function($payload);';
    await controller.evaluateJavascript(source: source);
  }
}
```

`lib/features/browser/browser_controller.dart`：

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 浏览器导航状态。
class BrowserController extends ChangeNotifier {
  InAppWebViewController? _webViewController;
  bool _loading = false;
  double _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;
  String? _errorText;

  bool get isLoading => _loading;
  double get progress => _progress;
  bool get canGoBack => _canGoBack;
  bool get canGoForward => _canGoForward;

  /// 主框架加载失败时的错误文案；为空表示正常。
  String? get errorText => _errorText;

  void attachWebView(InAppWebViewController controller) {
    _webViewController = controller;
  }

  /// WebView 被销毁（页面关闭）时清空引用，避免继续对失效 controller 发指令。
  void detachWebView() {
    _webViewController = null;
  }

  void updateLoading({required bool loading, double? progress}) {
    _loading = loading;
    if (progress != null) _progress = progress;
    notifyListeners();
  }

  void updateNavigationState({required bool canGoBack, required bool canGoForward}) {
    if (_canGoBack == canGoBack && _canGoForward == canGoForward) return;
    _canGoBack = canGoBack;
    _canGoForward = canGoForward;
    notifyListeners();
  }

  void setError(String? text) {
    _errorText = text;
    notifyListeners();
  }

  Future<void> load(Uri url) async {
    setError(null);
    await _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url.toString())));
  }

  Future<void> reload() async {
    setError(null);
    await _webViewController?.reload();
  }

  Future<void> goBack() async {
    setError(null);
    await _webViewController?.goBack();
  }

  Future<void> goForward() async {
    setError(null);
    await _webViewController?.goForward();
  }
}
```

- [ ] **Step 3: 写正式 BrowserPage**

`lib/features/browser/browser_page.dart`：

```dart
import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/bridge/bridge_protocol.dart';
import '../../core/bridge/js_channel.dart';
import '../capture/capture_controller.dart';
import '../capture/capture_script.dart';
import 'browser_controller.dart';
import 'url_normalizer.dart';
import 'webview_js_channel.dart';

/// 页面跳转且列表非空时的确认结果。
enum PageSwitchDecision { keep, clear }

class BrowserPage extends StatefulWidget {
  const BrowserPage({
    super.key,
    required this.initialUrl,
    required this.browser,
    required this.capture,
    required this.jsChannel,
    this.onTapCaptureCount,
    this.onPageSwitchNeeded,
    this.onBlobChunk,
    this.onScanLimitReached,
    this.contentOverride,
  });

  final Uri initialUrl;
  final BrowserController browser;
  final CaptureController capture;
  final JsChannelHolder jsChannel;

  /// 点击移动端「已捕获 N 张」浮动按钮。
  final VoidCallback? onTapCaptureCount;

  /// 检测到主框架跳到了新页面且列表非空时调用，返回用户选择。
  final Future<PageSwitchDecision> Function(String newPageUrl)? onPageSwitchNeeded;

  /// blob 分块交给下载模块处理。
  final void Function(BlobChunk chunk)? onBlobChunk;

  /// 扫描撞到 40 屏 / 60 秒上限时提示用户。
  final VoidCallback? onScanLimitReached;

  /// 仅测试使用：非空时不创建真实 WebView（平台视图在 widget 测试里不可用）。
  final Widget? contentOverride;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  final TextEditingController _addressController = TextEditingController();
  Key _webViewKey = UniqueKey();
  String? _lastMainFrameUrl;

  /// 最近一次成功加载的主框架 URL。WebView 重建（渲染进程崩溃）时用它当入口，
  /// 否则会退回 initialUrl，而不是用户当前所在的页面。
  String? _currentUrl;
  bool _autoScannedForCurrentUrl = false;

  @override
  void initState() {
    super.initState();
    _addressController.text = widget.initialUrl.toString();
  }

  @override
  void dispose() {
    _addressController.dispose();
    // 必须 detach：否则 JsChannelHolder 会一直持有指向已销毁 controller 的通道，
    // 下载模块（Task 14）调用它时既不抛 StateError 也发不出去，表现为「点了没反应」。
    widget.jsChannel.detach();
    widget.browser.detachWebView();
    super.dispose();
  }

  Future<void> _goToAddressBarValue() async {
    try {
      final url = normalizeInputUrl(_addressController.text);
      _currentUrl = url;
      await widget.browser.load(Uri.parse(url));
    } on FormatException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// 主框架加载完成：处理「已切换页面」提示，然后自动扫整页。
  ///
  /// 已知取舍：导航瞬间旧文档可能还留有排队中的桥消息，它们会把页 URL 短暂写回旧页；
  /// 下一条新页消息到达即自行纠正。不按 URL 过滤跨页消息——那会误杀 SPA 用
  /// pushState 改地址后（无主框架加载）发出的消息。
  Future<void> _afterMainFrameLoad(InAppWebViewController controller, String url) async {
    final capture = widget.capture;
    final isNewPage = _lastMainFrameUrl != null && _lastMainFrameUrl != url;
    _lastMainFrameUrl = url;
    if (isNewPage) {
      // 必须复位，否则新页不会自动扫描、且扫描状态条会停在上一页。
      // keepAssetsForNewPage 是复位扫描态的唯一出口（clear 会连列表一起清掉）。
      _autoScannedForCurrentUrl = false;
      var keepAssets = true;
      if (capture.rawCount > 0) {
        keepAssets = await widget.onPageSwitchNeeded?.call(url) != PageSwitchDecision.clear;
      }
      if (keepAssets) {
        capture.keepAssetsForNewPage(url);
      } else {
        capture.clear();
      }
    }
    if (_autoScannedForCurrentUrl) return;
    _autoScannedForCurrentUrl = true;
    unawaited(_startScan(controller));
  }

  Future<void> _startScan(InAppWebViewController controller) async {
    if (widget.capture.isScanning) return;
    await controller.evaluateJavascript(
      source: 'window.__imgcat && window.__imgcat.scan('
          '{"maxScreens": $kMaxScanScreens, "timeoutMs": ${kScanTimeout.inMilliseconds}});',
    );
  }

  Future<void> _abortScan(InAppWebViewController controller) async {
    await controller.evaluateJavascript(source: 'window.__imgcat && window.__imgcat.abort({});');
  }

  InAppWebViewController? _controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _AddressBar(
          controller: _addressController,
          browser: widget.browser,
          onSubmit: _goToAddressBarValue,
          onScanAgain: () => _controller == null ? null : _startScan(_controller!),
        ),
        ListenableBuilder(
          listenable: widget.capture,
          builder: (context, _) {
            final scan = widget.capture.scan;
            if (scan == null) return const SizedBox.shrink();
            return _ScanStatusBar(
              scan: scan,
              onAbort: _controller == null ? null : () => _abortScan(_controller!),
            );
          },
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: widget.browser,
            builder: (context, _) {
              // 错误页只覆盖、绝不替换 WebView：一旦把 InAppWebView 移出 widget 树，
              // 平台视图会被销毁、controller 变成失效引用，此后「重试」「地址栏」
              // 「前进后退」全部失效（debug 抛 FlutterError，release 静默无效）。
              return Stack(
                children: [
                  widget.contentOverride ?? _buildWebView(),
                  if (widget.browser.errorText != null)
                    Positioned.fill(
                      child: ColoredBox(
                        color: Theme.of(context).colorScheme.surface,
                        child: _ErrorView(
                          message: widget.browser.errorText!,
                          onRetry: () => unawaited(widget.browser.reload()),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildWebView() {
    return InAppWebView(
      key: _webViewKey,
      initialUrlRequest: URLRequest(url: WebUri(_currentUrl ?? widget.initialUrl.toString())),
      initialUserScripts: UnmodifiableListView<UserScript>([
        UserScript(
          source: kCaptureScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: false,
        ),
      ]),
      onWebViewCreated: (controller) {
        _controller = controller;
        widget.browser.attachWebView(controller);
        widget.jsChannel.attach(WebViewJsChannel(controller));
        controller.addJavaScriptHandler(
          handlerName: kBridgeHandlerName,
          callback: (args) {
            final message = BridgeMessage.parse(args.isNotEmpty ? args.first : null);
            if (message == null) return null;
            if (message is BlobChunk) {
              widget.onBlobChunk?.call(message);
            } else {
              widget.capture.accept(message);
            }
            return null;
          },
        );
      },
      onLoadStart: (controller, url) {
        widget.browser.updateLoading(loading: true, progress: 0);
      },
      onLoadStop: (controller, url) async {
        widget.browser.updateLoading(loading: false, progress: 1);
        final current = url?.toString();
        if (current != null) {
          _currentUrl = current;
          _addressController.text = current;
          await _afterMainFrameLoad(controller, current);
        }
        try {
          final canBack = await controller.canGoBack();
          final canForward = await controller.canGoForward();
          widget.browser.updateNavigationState(canGoBack: canBack, canGoForward: canForward);
        } catch (_) {
          // 页面正在销毁时忽略
        }
      },
      onProgressChanged: (controller, progress) {
        widget.browser.updateLoading(loading: progress < 100, progress: progress / 100);
      },
      onReceivedError: (controller, request, error) {
        if (request.isForMainFrame != true) return;
        // 取消类错误不是真失败：重定向/被取代的主框架请求常常报这个，
        // 若当成失败弹错误页，会把错误页永久盖在正常加载好的页面上。
        if (error.type == WebResourceErrorType.CANCELLED) return;
        // 主框架失败也必须复位扫描态，否则「扫描中失败 → 点重试加载同一 URL」时
        // isNewPage 为 false、_autoScannedForCurrentUrl 仍为 true、capture.scan
        // 仍停在 progress：状态条永久转圈且「重新扫描整页」永久失效。
        // 用 _lastMainFrameUrl（最后一次真正加载完成的主框架 URL）而不是失败的目标 URL：
        // 列表里的资产来自那个页面，降级下载拼 Referer 时才对得上。
        _autoScannedForCurrentUrl = false;
        widget.capture.keepAssetsForNewPage(_lastMainFrameUrl ?? widget.initialUrl.toString());
        widget.browser.setError('页面加载失败：${error.description}（${error.type}）');
      },
      onReceivedHttpError: (controller, request, response) {
        if (request.isForMainFrame == true && (response.statusCode ?? 0) >= 400) {
          widget.browser.setError('页面返回 ${response.statusCode}');
        }
      },
      // Android 渲染进程崩溃：重建 WebView，已抓列表保留在 CaptureController 里。
      onRenderProcessGone: (controller, detail) {
        if (!detail.didCrash || !Platform.isAndroid) return;
        if (!mounted) return;
        setState(() {
          _webViewKey = UniqueKey();
          _autoScannedForCurrentUrl = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('页面渲染进程崩溃，已重建，已抓列表保留')),
        );
      },
    );
  }
}
```

- [ ] **Step 4: 临时接线 `lib/main.dart`（否则仓库编译不过）**

新 `BrowserPage` 多了 3 个必填参数，而 `main.dart` 要到 Task 17 才定稿替换。本步只做最小接线，让它能编译运行，不要在这里加任何功能：

`lib/main.dart`：

```dart
import 'package:flutter/material.dart';

import 'core/bridge/js_channel.dart';
import 'features/browser/browser_controller.dart';
import 'features/browser/browser_page.dart';
import 'features/capture/capture_controller.dart';

/// Task 11 的临时接线（Task 17 会替换为正式应用壳）。
void main() => runApp(const SpikeApp());

class SpikeApp extends StatefulWidget {
  const SpikeApp({super.key});

  @override
  State<SpikeApp> createState() => _SpikeAppState();
}

class _SpikeAppState extends State<SpikeApp> {
  final BrowserController _browser = BrowserController();
  final CaptureController _capture = CaptureController();
  final JsChannelHolder _jsChannel = JsChannelHolder();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spike',
      home: Scaffold(
        appBar: AppBar(title: const Text('平台可行性验证')),
        body: BrowserPage(
          initialUrl: Uri.parse('https://example.com'),
          browser: _browser,
          capture: _capture,
          jsChannel: _jsChannel,
        ),
      ),
    );
  }
}
```

- [ ] **Step 5: 给桥回调补上扫描上限提示**

把 `onWebViewCreated` 里的 handler 改成下面这版（新增「扫到上限提示用户」的逻辑；`BrowserPage` 的 `onScanLimitReached` 字段已在 Step 3 的构造函数里声明）：

```dart
        // 抓取侧两处已知取舍：出现「少了一张图」时先看这里，别当 bug 反复修。
        // 1) 桥就绪后 flush 队列若抛错，这一批会被静默丢弃（不再重试）；
        // 2) srcset 候选拿不到宽高，其尺寸筛选与变体去重退化为「先到先得」。
        controller.addJavaScriptHandler(
          handlerName: kBridgeHandlerName,
          callback: (args) {
            final message = BridgeMessage.parse(args.isNotEmpty ? args.first : null);
            if (message == null) return null;
            if (message is BlobChunk) {
              widget.onBlobChunk?.call(message);
              return null;
            }
            final shouldWarnLimit = message is ScanProgress &&
                message.state == ScanState.limit &&
                !widget.capture.scanReachedLimit;
            widget.capture.accept(message);
            if (shouldWarnLimit) widget.onScanLimitReached?.call();
            return null;
          },
        );
```

- [ ] **Step 6: 写地址栏、扫描状态条、错误页三个私有组件**

追加到 `browser_page.dart` 末尾：

```dart
class _AddressBar extends StatelessWidget {
  const _AddressBar({
    required this.controller,
    required this.browser,
    required this.onSubmit,
    required this.onScanAgain,
  });

  final TextEditingController controller;
  final BrowserController browser;
  final VoidCallback onSubmit;
  final VoidCallback onScanAgain;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        children: [
          ListenableBuilder(
            listenable: browser,
            builder: (context, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: const Key('nav-back'),
                  onPressed: browser.canGoBack ? browser.goBack : null,
                  icon: const Icon(Icons.arrow_back),
                  tooltip: '后退',
                ),
                IconButton(
                  key: const Key('nav-forward'),
                  onPressed: browser.canGoForward ? browser.goForward : null,
                  icon: const Icon(Icons.arrow_forward),
                  tooltip: '前进',
                ),
                IconButton(
                  key: const Key('nav-reload'),
                  onPressed: browser.reload,
                  icon: const Icon(Icons.refresh),
                  tooltip: '刷新',
                ),
              ],
            ),
          ),
          Expanded(
            child: TextField(
              key: const Key('address-field'),
              controller: controller,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => onSubmit(),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                hintText: '输入网址，例如 example.com',
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            key: const Key('address-go'),
            onPressed: onSubmit,
            icon: const Icon(Icons.arrow_circle_right_outlined),
            tooltip: '打开',
          ),
          IconButton(
            key: const Key('scan-again'),
            onPressed: onScanAgain,
            icon: const Icon(Icons.search),
            tooltip: '重新扫描整页',
          ),
        ],
      ),
    );
  }
}

class _ScanStatusBar extends StatelessWidget {
  const _ScanStatusBar({required this.scan, required this.onAbort});

  final ScanProgress scan;
  final VoidCallback? onAbort;

  @override
  Widget build(BuildContext context) {
    final scanner = scan;
    if (scanner.state == ScanState.done || scanner.state == ScanState.aborted) {
      return const SizedBox.shrink();
    }
    final text = scanner.state == ScanState.limit
        ? '已达扫描上限，可手动继续滚动后再次扫描'
        : '正在扫描第 ${scanner.screen}/${scanner.maxScreens} 屏 · 已捕获 ${scanner.found} 张';
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, key: const Key('scan-status'), style: Theme.of(context).textTheme.bodySmall)),
          if (scanner.isRunning && onAbort != null)
            TextButton(key: const Key('scan-abort'), onPressed: onAbort, child: const Text('中断')),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off, size: 48),
          const SizedBox(height: 12),
          Text(message, key: const Key('page-error'), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(key: const Key('page-retry'), onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
```

- [ ] **Step 7: 静态分析**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter analyze`

Expected: `No issues found!`（若 `onProgressChanged` 等回调名与实际版本不符，按 `flutter_inappwebview` 6.x 的实际 API 改名，保持行为不变。）

再跑一遍既有单测确认没有回归：`/Users/ling/fvm/versions/3.47.4/bin/flutter test`（应仍全绿）。

- [ ] **Step 8: 提交**

```bash
git add lib/features/browser lib/core/bridge/js_channel.dart lib/main.dart
git commit -m "feat(browser): WebView 页（注入抓取脚本、桥回调、自动扫整页、错误页、崩溃重建）"
```

**⚠️ 已知待修（Task 17 接线 `onPageSwitchNeeded` 时必须一并处理，别当成已完成）：**

「保留/清空」确认发生在**主框架加载完成之后**，而 `kCaptureScript` 的 PerformanceObserver / MutationObserver 在新页 DOM 解析后约 300ms 就会自行推一批图。等用户回答对话框时新页的图**已经在 `_capture` 里**，此时 `capture.clear()` 会把它们一并抹掉；而 `flush()` 只推「新增/有变化」的条目，后续 `scan()` 不会重新推送 → **静默丢图**。

修法（Task 17 的 **Step 5** 落地，三处都在，缺一条都修不掉）：
1. `lib/features/capture/capture_controller.dart` 加 `void removeUrls(Iterable<String> urls)`：按 URL 从 `_byUrl` 删除，并同步从 `_selected` 移除（`clear()` 保留不动）。注意这是 Task 10 产出的文件，只加这一个方法、别顺手改别的。
2. `lib/features/browser/browser_page.dart`：新增字段 `Set<String> _urlsBeforeNavigation = const {};`，在 `onLoadStart`（主框架）里先快照 `widget.capture.rawAssets.map((a) => a.url).toSet()`；`_afterMainFrameLoad` 的 clear 分支由 `capture.clear()` 改为 `capture.removeUrls(_urlsBeforeNavigation)`（空集时才退化为 `clear()`）。
3. 对话框要显示「上一个页面」：回调签名改为 `Future<PageSwitchDecision> Function(String previousUrl, String newUrl)?`（`previousUrl` 是更新前的 `_lastMainFrameUrl`），`BrowserPage` 传参时用更新前的值；**不要让 Task 17 读 `capture.pageUrl`** —— 那时它已被新页消息覆写。

---

## Task 12: blob 分块接收与落盘

**Files:**
- Create: `lib/features/download/blob_file_writer.dart`
- Test: `test/features/download/blob_file_writer_test.dart`

- [ ] **Step 1: 写失败的测试**

`test/features/download/blob_file_writer_test.dart`：

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:download_image/core/bridge/bridge_protocol.dart';
import 'package:download_image/features/download/blob_file_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('imgcat_test'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  BlobChunk chunk(String id, int seq, List<int> bytes, {bool last = false}) {
    return BlobChunk(id: id, seq: seq, data: base64Encode(bytes), last: last);
  }

  test('按序写入所有分块，内容与原始字节一致', () async {
    final file = File('${tempDir.path}/out.bin');
    final writer = BlobFileWriter(file);
    await writer.open();

    await writer.add(chunk('dl-1', 0, Uint8List.fromList(List.filled(3, 1))));
    expect(writer.receivedBytes, 3);
    expect(writer.isComplete, isFalse);

    await writer.add(chunk('dl-1', 1, Uint8List.fromList(List.filled(2, 2)), last: true));
    await writer.close();

    expect(writer.receivedBytes, 5);
    expect(writer.isComplete, isTrue);
    expect(await file.length(), 5);
    expect(await file.readAsBytes(), [1, 1, 1, 2, 2]);
  });

  test('空分块（0 字节图片）也能正常完成', () async {
    final file = File('${tempDir.path}/empty.bin');
    final writer = BlobFileWriter(file);
    await writer.open();
    await writer.add(chunk('dl-1', 0, const [], last: true));
    await writer.close();
    expect(writer.isComplete, isTrue);
    expect(await file.length(), 0);
  });

  test('分块乱序抛 StateError', () async {
    final file = File('${tempDir.path}/bad.bin');
    final writer = BlobFileWriter(file);
    await writer.open();
    expect(
      () => writer.add(chunk('dl-1', 1, const [1])),
      throwsA(isA<StateError>()),
    );
    await writer.close();
  });

  test('未打开或已关闭时 add 抛可辨认的 StateError', () async {
    final file = File('${tempDir.path}/lifecycle.bin');
    final writer = BlobFileWriter(file);
    expect(
      () => writer.add(chunk('dl-1', 0, const [1])),
      throwsA(isA<StateError>()),
      reason: 'open 之前不接受分块',
    );
    await writer.open();
    await writer.close();
    expect(
      () => writer.add(chunk('dl-1', 0, const [1])),
      throwsA(isA<StateError>()),
      reason: 'close 之后不接受分块',
    );
  });

  test('超过 512KB 的大文件分块写入后大小正确', () async {
    final file = File('${tempDir.path}/big.bin');
    final writer = BlobFileWriter(file);
    await writer.open();
    final block = Uint8List(kBlobChunkBytes);
    await writer.add(chunk('dl-1', 0, block));
    await writer.add(chunk('dl-1', 1, Uint8List(1000), last: true));
    await writer.close();
    expect(await file.length(), kBlobChunkBytes + 1000);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/features/download/blob_file_writer_test.dart`

Expected: FAIL，`Undefined name 'BlobFileWriter'`。

- [ ] **Step 3: 写最小实现**

`lib/features/download/blob_file_writer.dart`：

```dart
import 'dart:convert';
import 'dart:io';

import '../../core/bridge/bridge_protocol.dart';

/// 把 JS 回传的 base64 分块边收边写入临时文件，避免大图整体驻留内存。
class BlobFileWriter {
  BlobFileWriter(this.file);

  final File file;

  RandomAccessFile? _raf;
  int _expectedSeq = 0;
  int _receivedBytes = 0;
  bool _complete = false;

  /// 已接收字节数。
  int get receivedBytes => _receivedBytes;

  /// 收到 last 分块后为 true。
  bool get isComplete => _complete;

  Future<void> open() async {
    await file.parent.create(recursive: true);
    _raf = await file.open(mode: FileMode.writeOnly);
  }

  Future<void> add(BlobChunk chunk) async {
    // 显式生命周期检查：否则 _raf! 会抛 `Null check operator used on a null value`，
    // 调用方（Task 14 的接收器）拿到的是一个认不出来的 TypeError。
    final raf = _raf;
    if (raf == null) {
      throw StateError('writer 未打开或已关闭，不能接收分块（seq=${chunk.seq}）');
    }
    if (chunk.seq != _expectedSeq) {
      throw StateError('分块乱序：期望 $_expectedSeq，收到 ${chunk.seq}');
    }
    final bytes = base64Decode(chunk.data);
    await raf.writeFrom(bytes);
    _receivedBytes += bytes.length;
    _expectedSeq++;
    if (chunk.last) _complete = true;
  }

  Future<void> close() async {
    await _raf?.close();
    _raf = null;
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/features/download/blob_file_writer_test.dart`

Expected: `All tests passed!`

- [ ] **Step 5: 提交**

```bash
git add lib/features/download/blob_file_writer.dart test/features/download/blob_file_writer_test.dart
git commit -m "feat(download): blob 分块边收边写临时文件"
```

**留给 Task 14 的三条（本任务不实现）：**
1. `isComplete` 只表示「收到 last」，协议里没有总长度字段，**本类无法自检截断**。兜底放在 Task 14：`fetchAsBase64` 的 `call` 返回值带 `length`，收完后拿它与 `writer.receivedBytes` 比对，不一致按失败降级原生下载。
2. `BlobChunk.error` 非空（JS 侧 fetch 失败）由接收器判失败，不要送进 `writer.add`（否则会被当成 0 字节的正常分块，`last=true` 时还会置成 complete）。
3. `browser_page.dart` 的 `onBlobChunk` 是 `void Function(BlobChunk)`，回调里不 await —— `add` 抛的 `StateError` 会变成未处理的异步异常。Task 14 的接收器必须在内部 try/catch，别把异常漏给平台通道。

---

## Task 13: 保存目标与四端平台配置

**Files:**
- Create: `lib/features/download/save_target.dart`、`lib/features/download/file_name.dart`
- Test: `test/features/download/file_name_test.dart`、`test/features/download/save_target_test.dart`
- Modify: `macos/Runner/DebugProfile.entitlements`、`macos/Runner/Release.entitlements`、`android/app/src/main/AndroidManifest.xml`、`ios/Runner/Info.plist`

- [ ] **Step 1: 写 file_name 的失败测试**

`test/features/download/file_name_test.dart`：

```dart
import 'package:download_image/features/download/file_name.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildFileName', () {
    test('取路径最后一段，解码百分号转义', () {
      expect(buildFileName('https://a.com/p/img%20a.JPG'), 'img_a.JPG');
      expect(buildFileName('https://a.com/p/i.jpg?w=300'), 'i.jpg');
    });

    test('pathSegments 已解码，不能再解码一次', () {
      // 含 % 与非 ASCII 的文件名若被二次解码会抛 ArgumentError。
      expect(buildFileName('https://a.com/100%25.jpg'), '100_.jpg');
      expect(buildFileName('https://a.com/%E4%B8%AD%E6%96%87.jpg'), '__.jpg');
    });

    test('路径没有文件名时回退为 image，用 mime 补扩展名', () {
      expect(buildFileName('https://a.com/'), 'image');
      expect(buildFileName('https://a.com/p', mimeType: 'image/png'), 'p.png');
      expect(buildFileName('https://a.com/', mimeType: 'image/svg+xml'), 'image.svg');
    });

    test('没有扩展名时用 mime 补', () {
      expect(buildFileName('https://a.com/photo', mimeType: 'image/webp'), 'photo.webp');
      expect(buildFileName('https://a.com/photo', mimeType: 'image/jpeg'), 'photo.jpg');
    });

    test('危险字符被替换成下划线', () {
      expect(buildFileName('https://a.com/../../etc/passwd'), 'passwd');
      expect(buildFileName('https://a.com/a:b*c.jpg'), 'a_b_c.jpg');
    });

    test('mime 无法识别时不补扩展名', () {
      expect(buildFileName('https://a.com/photo', mimeType: 'application/octet-stream'), 'photo');
    });
  });

  group('uniqueFileName', () {
    test('第 0 个保持原名，之后追加序号', () {
      expect(uniqueFileName('i.jpg', 0), 'i.jpg');
      expect(uniqueFileName('i.jpg', 1), 'i (1).jpg');
      expect(uniqueFileName('i.jpg', 12), 'i (12).jpg');
    });

    test('无扩展名时直接追加', () {
      expect(uniqueFileName('image', 2), 'image (2)');
    });
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/features/download/file_name_test.dart`

Expected: FAIL，`Undefined name 'buildFileName'`。

- [ ] **Step 3: 实现 file_name**

`lib/features/download/file_name.dart`：

```dart
/// mime → 扩展名，只覆盖一期支持的格式。
const Map<String, String> _mimeExtensions = {
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/png': 'png',
  'image/gif': 'gif',
  'image/webp': 'webp',
  'image/svg+xml': 'svg',
};

/// 从 URL 推导保存用的文件名：不信任 URL，路径段与危险字符都会被清洗。
/// 百分号转义由 `Uri.pathSegments` 负责，这里不再解码，避免二次解码崩溃。
String buildFileName(String url, {String? mimeType}) {
  final uri = Uri.tryParse(url);
  var name = '';
  if (uri != null && uri.pathSegments.isNotEmpty) {
    name = uri.pathSegments.last;
  }
  name = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  name = name.replaceAll(RegExp(r'^\.+'), '');
  if (name.isEmpty) name = 'image';
  if (!name.contains('.')) {
    final ext = _mimeExtensions[mimeType?.toLowerCase()];
    if (ext != null) name = '$name.$ext';
  }
  return name;
}

/// 下载目录里已存在同名文件时使用的备选名：`i.jpg` → `i (1).jpg`。
String uniqueFileName(String fileName, int index) {
  if (index <= 0) return fileName;
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0) return '$fileName ($index)';
  return '${fileName.substring(0, dot)} ($index)${fileName.substring(dot)}';
}
```

注意：测试里 `buildFileName('https://a.com/../../etc/passwd')` 期望 `passwd` —— `Uri.pathSegments` 会保留 `..` 段但最后一段是 `passwd`，`^\.+` 规则负责把纯点洗掉，不会影响本用例。

- [ ] **Step 4: 写 save_target 的失败测试**

`test/features/download/save_target_test.dart`：

```dart
import 'dart:io';

import 'package:download_image/features/download/save_target.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late Directory downloadsDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('imgcat_save');
    downloadsDir = Directory('${tempDir.path}/Downloads')..createSync(recursive: true);
  });
  tearDown(() => tempDir.deleteSync(recursive: true));

  test('下载目录写入：文件落到目标目录且内容一致', () async {
    final temp = File('${tempDir.path}/tmp.jpg')..writeAsBytesSync([1, 2, 3]);
    final target = DownloadsSaveTarget(downloadsDirectory: () async => downloadsDir);

    final savedPath = await target.save(tempFile: temp, fileName: 'pic.jpg', mimeType: 'image/jpeg');

    expect(savedPath, '${downloadsDir.path}/pic.jpg');
    expect(File(savedPath).readAsBytesSync(), [1, 2, 3]);
  });

  test('重名时自动追加序号，不覆盖已有文件', () async {
    File('${downloadsDir.path}/pic.jpg').writeAsBytesSync([9]);
    final temp = File('${tempDir.path}/tmp.jpg')..writeAsBytesSync([1]);
    final target = DownloadsSaveTarget(downloadsDirectory: () async => downloadsDir);

    final savedPath = await target.save(tempFile: temp, fileName: 'pic.jpg');

    expect(savedPath, '${downloadsDir.path}/pic (1).jpg');
    expect(File('${downloadsDir.path}/pic.jpg').readAsBytesSync(), [9]);
  });

  test('目标目录不存在时自动创建', () async {
    final nested = Directory('${tempDir.path}/none/here');
    final temp = File('${tempDir.path}/tmp.jpg')..writeAsBytesSync([1]);
    final target = DownloadsSaveTarget(downloadsDirectory: () async => nested);

    final savedPath = await target.save(tempFile: temp, fileName: 'a.jpg');

    expect(Directory('${tempDir.path}/none/here').existsSync(), isTrue);
    expect(File(savedPath).existsSync(), isTrue);
  });

  test('resolveFileName 在无冲突时返回原名', () {
    expect(resolveFileName('i.jpg', (name) => false), 'i.jpg');
    expect(resolveFileName('i.jpg', (name) => name == 'i.jpg'), 'i (1).jpg');
    expect(resolveFileName('i.jpg', (name) => name != 'i (5).jpg'), 'i (5).jpg');
  });
}
```

- [ ] **Step 5: 运行确认失败**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/features/download/save_target_test.dart`

Expected: FAIL，`Undefined name 'DownloadsSaveTarget'`。

- [ ] **Step 6: 实现 save_target**

`lib/features/download/save_target.dart`：

```dart
import 'dart:io';

import 'package:app_settings/app_settings.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import 'file_name.dart';

/// 保存失败。[needsPermission] 为 true 时 UI 应引导用户去系统设置。
class SaveException implements Exception {
  SaveException(this.message, {this.needsPermission = false});

  final String message;
  final bool needsPermission;

  @override
  String toString() => message;
}

/// 在 [exists] 判定下挑一个不冲突的文件名。
String resolveFileName(String fileName, bool Function(String candidate) exists) {
  if (!exists(fileName)) return fileName;
  for (var index = 1; index < 1000; index++) {
    final candidate = uniqueFileName(fileName, index);
    if (!exists(candidate)) return candidate;
  }
  return uniqueFileName(fileName, DateTime.now().millisecondsSinceEpoch);
}

/// 保存目标的抽象：这是四端唯一的平台差异点。
abstract class SaveTarget {
  /// 返回保存后的可读位置描述（桌面是绝对路径，移动端是相册名）。
  Future<String> save({required File tempFile, required String fileName, String? mimeType});

  /// 引导用户去系统设置（移动端相册权限被拒时）。
  Future<void> openPermissionSettings();
}

/// 按当前平台选择保存目标。
SaveTarget createSaveTarget() {
  if (Platform.isAndroid || Platform.isIOS) return const GallerySaveTarget();
  return DownloadsSaveTarget();
}

/// 桌面端：写系统下载目录。
/// macOS 沙盒下依赖 `com.apple.security.files.downloads.read-write` entitlement，无需授权弹窗。
class DownloadsSaveTarget implements SaveTarget {
  DownloadsSaveTarget({Future<Directory?> Function()? downloadsDirectory})
      : _downloadsDirectory = downloadsDirectory ?? getDownloadsDirectory;

  final Future<Directory?> Function() _downloadsDirectory;

  @override
  Future<String> save({required File tempFile, required String fileName, String? mimeType}) async {
    try {
      final dir = await _downloadsDirectory();
      if (dir == null) {
        throw SaveException('无法定位系统下载目录');
      }
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final resolved = resolveFileName(fileName, (candidate) => File('${dir.path}/$candidate').existsSync());
      final target = File('${dir.path}/$resolved');
      await tempFile.copy(target.path);
      return target.path;
    } on SaveException {
      // 已是对外承诺的失败类型，原样透传，不再套一层前缀。
      rethrow;
    } catch (e) {
      throw SaveException('保存到下载目录失败：$e');
    }
  }

  @override
  Future<void> openPermissionSettings() async {
    await AppSettings.openAppSettings();
  }
}

/// 移动端：写系统相册。
class GallerySaveTarget implements SaveTarget {
  const GallerySaveTarget({this.album = 'ImgCat'});

  final String album;

  @override
  Future<String> save({required File tempFile, required String fileName, String? mimeType}) async {
    try {
      await Gal.putImage(tempFile.path, album: album);
      return '相册/$album';
    } on GalException catch (e) {
      throw SaveException(
        e.type == GalExceptionType.accessDenied ? '没有相册写入权限' : '保存到相册失败：${e.type.message}',
        needsPermission: e.type == GalExceptionType.accessDenied,
      );
    }
  }

  @override
  Future<void> openPermissionSettings() async {
    await AppSettings.openAppSettings(type: AppSettingsType.settings);
  }
}
```

若 `GalExceptionType.accessDenied` / `e.type.message` 与 `gal` 实际 API 不符，按实际枚举名调整，保持「权限被拒 → `needsPermission: true`」这一行为不变。

- [ ] **Step 7: 运行两个测试文件确认通过**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/features/download/file_name_test.dart test/features/download/save_target_test.dart`

Expected: `All tests passed!`

- [ ] **Step 8: 写四端平台配置**

`macos/Runner/DebugProfile.entitlements` 与 `macos/Runner/Release.entitlements` 都加上（保留原有 key）：

```xml
	<key>com.apple.security.files.downloads.read-write</key>
	<true/>
```

`android/app/src/main/AndroidManifest.xml` 的 `<manifest>` 下加（`INTERNET` 模板只在 debug/profile manifest 里，主 manifest 必须补）：

```xml
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28"/>
```

`ios/Runner/Info.plist` 的顶层 `<dict>` 里加：

```xml
	<key>NSPhotoLibraryAddUsageDescription</key>
	<string>需要把抓取到的图片保存到你的相册</string>
```

Windows 无需额外声明。

- [ ] **Step 9: 提交**

```bash
git add lib/features/download/save_target.dart lib/features/download/file_name.dart test/features/download macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements android/app/src/main/AndroidManifest.xml ios/Runner/Info.plist
git commit -m "feat(download): 保存目标（相册/下载目录）与四端权限声明"
```

---

## Task 14: 下载通道（blob 首选 + Dio 降级）与下载队列

**Files:**
- Create: `lib/features/download/webview_blob_fetcher.dart`、`lib/features/download/native_fetcher.dart`、`lib/features/download/download_service.dart`、`lib/features/download/download_controller.dart`
- Test: `test/features/download/download_controller_test.dart`

- [ ] **Step 1: 写 blob 接收器**

`lib/features/download/webview_blob_fetcher.dart`：

```dart
import 'dart:async';
import 'dart:io';

import '../../core/bridge/bridge_protocol.dart';
import '../../core/bridge/js_channel.dart';
import '../../core/model/image_asset.dart';
import 'blob_file_writer.dart';

/// blob 通道失败（HTTP 错误、桥超时等），调用方据此降级到原生直下。
class BlobFetchException implements Exception {
  BlobFetchException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// blob 分块接收器的最小接口：下载控制器只依赖它，测试可轻松替换。
abstract class BlobChunkSink {
  Future<void> accept(BlobChunk chunk);
}

/// 在页面内 `fetch` 取图片，512KB 分块回传并写进临时文件。
/// 一次只处理一个下载（下载队列本身就是串行的）。
class WebViewBlobFetcher implements BlobChunkSink {
  WebViewBlobFetcher(this.channel);

  final JsChannel channel;

  BlobFileWriter? _writer;
  Completer<File>? _completer;
  String? _activeId;
  int _counter = 0;

  Future<File> fetchToFile(ImageAsset asset, File destination) async {
    if (_writer != null) {
      throw BlobFetchException('已有 blob 下载在进行');
    }
    final id = 'dl-${DateTime.now().microsecondsSinceEpoch}-${_counter++}';
    final writer = BlobFileWriter(destination);
    await writer.open();
    _writer = writer;
    _activeId = id;
    final completer = Completer<File>();
    _completer = completer;

    try {
      await channel.call('fetchAsBase64', {
        'url': asset.url,
        'id': id,
        'chunkSize': kBlobChunkBytes,
      });
    } catch (e) {
      await _reset();
      throw BlobFetchException('调用页面内 fetch 失败：$e');
    }

    try {
      return await completer.future.timeout(const Duration(seconds: 45));
    } on TimeoutException {
      await _reset();
      throw BlobFetchException('blob 通道超时');
    }
  }

  /// BrowserPage 把 BlobChunk 消息转进来。
  @override
  Future<void> accept(BlobChunk chunk) async {
    final writer = _writer;
    if (writer == null || chunk.id != _activeId) return;
    if (chunk.error != null) {
      final completer = _completer;
      await _reset();
      completer?.completeError(BlobFetchException('页面内 fetch 失败：${chunk.error}'));
      return;
    }
    await writer.add(chunk);
    if (writer.isComplete) {
      final file = writer.file;
      final completer = _completer;
      await _reset(keepFile: true);
      completer?.complete(file);
    }
  }

  Future<void> _reset({bool keepFile = false}) async {
    final writer = _writer;
    _writer = null;
    _activeId = null;
    _completer = null;
    if (writer != null) {
      await writer.close();
      if (!keepFile) {
        try {
          if (await writer.file.exists()) await writer.file.delete();
        } catch (_) {
          // 清理失败不影响主流程
        }
      }
    }
  }
}
```

- [ ] **Step 2: 写原生直下**

`lib/features/download/native_fetcher.dart`：

```dart
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/model/image_asset.dart';

/// 原生直下失败，交由上层标记该项失败。
class NativeFetchException implements Exception {
  NativeFetchException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 降级通道：Dio 携带 WebView 导出的 Cookie 与 Referer 直接下载。
/// 用 download 直接落盘（不驻留内存），大图也安全。
class NativeFetcher {
  NativeFetcher({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  Future<File> fetchToFile(
    ImageAsset asset,
    File destination, {
    String? referer,
    void Function(int received, int? total)? onProgress,
  }) async {
    try {
      final headers = <String, String>{'Accept': 'image/*,*/*;q=0.8'};
      if (referer != null && referer.isNotEmpty) headers['Referer'] = referer;
      final cookieHeader = await _cookieHeader(asset.url);
      if (cookieHeader.isNotEmpty) headers['Cookie'] = cookieHeader;

      await destination.parent.create(recursive: true);
      final response = await _dio.download(
        asset.url,
        destination.path,
        options: Options(headers: headers, followRedirects: true, validateStatus: (code) => code != null && code < 400),
        onReceiveProgress: onProgress,
      );
      final status = response.statusCode ?? 0;
      if (status >= 400) {
        throw NativeFetchException('原生直下返回 HTTP $status');
      }
      return destination;
    } on DioException catch (e) {
      throw NativeFetchException('原生直下失败：${e.response?.statusCode ?? e.type.name}');
    }
  }

  Future<String> _cookieHeader(String url) async {
    try {
      final cookies = await CookieManager.instance().getCookies(url: WebUri(url));
      return cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
    } catch (_) {
      return '';
    }
  }
}
```

- [ ] **Step 3: 写下载服务（首选 blob，失败降级原生）**

`lib/features/download/download_service.dart`：

```dart
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/model/image_asset.dart';
import 'file_name.dart';
import 'native_fetcher.dart';
import 'save_target.dart';
import 'webview_blob_fetcher.dart';

/// 一次下载的结果。
class DownloadOutcome {
  const DownloadOutcome({
    required this.location,
    required this.usedFallback,
    required this.bytes,
  });

  /// 相册名或桌面绝对路径。
  final String location;

  /// 是否走了 Dio 原生降级通道。
  final bool usedFallback;

  /// 落盘字节数；原生通道未知时为 null。
  final int? bytes;
}

/// 下载控制器依赖的最小接口，便于测试替换。
abstract class DownloadExecutor {
  Future<DownloadOutcome> download(ImageAsset asset);

  Future<void> openPermissionSettings();
}

class DownloadService implements DownloadExecutor {
  DownloadService({
    required this.blobFetcher,
    required this.saveTarget,
    NativeFetcher? nativeFetcher,
    Future<Directory> Function()? tempDirectory,
    this.refererProvider,
  })  : _nativeFetcher = nativeFetcher ?? NativeFetcher(),
        _tempDirectory = tempDirectory ?? getTemporaryDirectory;

  final WebViewBlobFetcher blobFetcher;
  final SaveTarget saveTarget;
  final NativeFetcher _nativeFetcher;
  final Future<Directory> Function() _tempDirectory;

  /// 页面 URL，用作下载请求的 Referer。
  final String? Function()? refererProvider;

  @override
  Future<DownloadOutcome> download(ImageAsset asset) async {
    final fileName = buildFileName(asset.url, mimeType: asset.mimeType);
    final tempDir = await _tempDirectory();
    final tempFile = File(p.join(tempDir.path, 'imgcat_$fileName'));

    var usedFallback = false;
    int? bytes;
    try {
      final file = await blobFetcher.fetchToFile(asset, tempFile);
      bytes = await file.length();
    } catch (_) {
      // 首选失败：降级原生直下。
      usedFallback = true;
      final file = await _nativeFetcher.fetchToFile(
        asset,
        tempFile,
        referer: refererProvider?.call(),
      );
      bytes = await file.length();
    }

    final location = await saveTarget.save(
      tempFile: tempFile,
      fileName: fileName,
      mimeType: asset.mimeType,
    );
    try {
      if (await tempFile.exists()) await tempFile.delete();
    } catch (_) {
      // 临时文件清理失败不影响结果
    }
    return DownloadOutcome(location: location, usedFallback: usedFallback, bytes: bytes);
  }

  @override
  Future<void> openPermissionSettings() => saveTarget.openPermissionSettings();
}
```

- [ ] **Step 4: 写下载控制器**

`lib/features/download/download_controller.dart`：

```dart
import 'package:flutter/foundation.dart';

import '../../core/bridge/bridge_protocol.dart';
import '../../core/model/image_asset.dart';
import 'download_service.dart';
import 'save_target.dart';
import 'webview_blob_fetcher.dart';

enum DownloadStatus { idle, running, done, failed }

class DownloadController extends ChangeNotifier {
  DownloadController({required this.executor, required this.blobSink});

  /// 下载执行器（真实实现是 DownloadService）。
  final DownloadExecutor executor;

  /// blob 分块接收器（真实实现是 WebViewBlobFetcher）。
  final BlobChunkSink blobSink;

  final Map<String, DownloadStatus> _status = <String, DownloadStatus>{};
  final Map<String, String> _errors = <String, String>{};
  final Map<String, String> _locations = <String, String>{};
  final List<String> _failedUrls = <String>[];

  bool _busy = false;
  int _completed = 0;
  int _total = 0;
  bool _permissionDenied = false;

  bool get isBusy => _busy;
  int get completed => _completed;
  int get total => _total;

  /// 最近一次下载因为权限被拒。
  bool get needsPermission => _permissionDenied;

  List<String> get failedUrls => List.unmodifiable(_failedUrls);

  DownloadStatus statusOf(String url) => _status[url] ?? DownloadStatus.idle;

  String? errorOf(String url) => _errors[url];

  String? locationOf(String url) => _locations[url];

  String get progressLabel => _busy ? '正在下载 $_completed/$_total' : '';

  /// BrowserPage 把 blob 分块转进来。
  Future<void> acceptBlobChunk(BlobChunk chunk) => blobSink.accept(chunk);

  /// 串行下载；单项失败不影响其他项（设计文档第 9 节）。
  Future<void> downloadAll(List<ImageAsset> assets) async {
    if (_busy || assets.isEmpty) return;
    _busy = true;
    _total = assets.length;
    _completed = 0;
    _permissionDenied = false;
    notifyListeners();

    for (final asset in assets) {
      _status[asset.url] = DownloadStatus.running;
      notifyListeners();
      try {
        final outcome = await executor.download(asset);
        _status[asset.url] = DownloadStatus.done;
        _locations[asset.url] = outcome.location;
        _errors.remove(asset.url);
        _failedUrls.remove(asset.url);
      } catch (e) {
        _status[asset.url] = DownloadStatus.failed;
        _errors[asset.url] = e is SaveException ? e.message : e.toString();
        _permissionDenied = _permissionDenied || (e is SaveException && e.needsPermission);
        if (!_failedUrls.contains(asset.url)) _failedUrls.add(asset.url);
      }
      _completed++;
      notifyListeners();
    }

    _busy = false;
    notifyListeners();
  }

  Future<void> retry(ImageAsset asset) => downloadAll(<ImageAsset>[asset]);

  Future<void> openPermissionSettings() => executor.openPermissionSettings();
}
```

- [ ] **Step 5: 写共用的测试替身**

`test/support/fake_download.dart`（Task 15 也会用）：

```dart
import 'package:download_image/core/bridge/bridge_protocol.dart';
import 'package:download_image/core/model/image_asset.dart';
import 'package:download_image/features/download/download_controller.dart';
import 'package:download_image/features/download/download_service.dart';
import 'package:download_image/features/download/save_target.dart';
import 'package:download_image/features/download/webview_blob_fetcher.dart';

/// 可控的假下载执行器：按 URL 决定成功或抛错。
class FakeDownloadExecutor implements DownloadExecutor {
  FakeDownloadExecutor({
    Set<String>? failingUrls,
    Set<String>? permissionUrls,
  })  : failingUrls = failingUrls ?? <String>{},
        permissionUrls = permissionUrls ?? <String>{};

  final Set<String> failingUrls;
  final Set<String> permissionUrls;
  final List<String> calls = <String>[];
  bool permissionSettingsOpened = false;

  @override
  Future<DownloadOutcome> download(ImageAsset asset) async {
    calls.add(asset.url);
    if (permissionUrls.contains(asset.url)) {
      throw SaveException('没有相册写入权限', needsPermission: true);
    }
    if (failingUrls.contains(asset.url)) {
      throw SaveException('镜像 403');
    }
    return DownloadOutcome(location: '/Downloads/x.jpg', usedFallback: false, bytes: 3);
  }

  @override
  Future<void> openPermissionSettings() async {
    permissionSettingsOpened = true;
  }
}

/// 什么都不做的 blob 接收器。
class FakeBlobSink implements BlobChunkSink {
  final List<BlobChunk> chunks = <BlobChunk>[];

  @override
  Future<void> accept(BlobChunk chunk) async {
    chunks.add(chunk);
  }
}

/// 给 widget 测试用的下载控制器。
DownloadController fakeDownloadController({FakeDownloadExecutor? executor}) {
  return DownloadController(
    executor: executor ?? FakeDownloadExecutor(),
    blobSink: FakeBlobSink(),
  );
}
```

- [ ] **Step 6: 写下载控制器测试**

`test/features/download/download_controller_test.dart`：

```dart
import 'package:download_image/core/bridge/bridge_protocol.dart';
import 'package:download_image/core/model/image_asset.dart';
import 'package:download_image/features/download/download_controller.dart';
import 'package:download_image/features/download/download_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_download.dart';

ImageAsset _asset(String url) => ImageAsset(url: url, width: 100, height: 100);

void main() {
  test('串行下载全部成功，状态与位置写回', () async {
    final executor = FakeDownloadExecutor();
    final controller = DownloadController(executor: executor, blobSink: FakeBlobSink());

    await controller.downloadAll([_asset('https://a.com/1.jpg'), _asset('https://a.com/2.jpg')]);

    expect(executor.calls, ['https://a.com/1.jpg', 'https://a.com/2.jpg']);
    expect(controller.statusOf('https://a.com/1.jpg'), DownloadStatus.done);
    expect(controller.locationOf('https://a.com/2.jpg'), '/Downloads/x.jpg');
    expect(controller.isBusy, isFalse);
    expect(controller.completed, 2);
    expect(controller.failedUrls, isEmpty);
  });

  test('单项失败不中断其他项，并记录失败与错误文案', () async {
    final executor = FakeDownloadExecutor(failingUrls: {'https://a.com/bad.jpg'});
    final controller = DownloadController(executor: executor, blobSink: FakeBlobSink());

    await controller.downloadAll([
      _asset('https://a.com/bad.jpg'),
      _asset('https://a.com/ok.jpg'),
    ]);

    expect(controller.statusOf('https://a.com/bad.jpg'), DownloadStatus.failed);
    expect(controller.errorOf('https://a.com/bad.jpg'), '镜像 403');
    expect(controller.statusOf('https://a.com/ok.jpg'), DownloadStatus.done);
    expect(controller.failedUrls, ['https://a.com/bad.jpg']);
  });

  test('权限被拒时置 needsPermission，重试成功后清除', () async {
    final executor = FakeDownloadExecutor(permissionUrls: {'https://a.com/p.jpg'});
    final controller = DownloadController(executor: executor, blobSink: FakeBlobSink());

    await controller.downloadAll([_asset('https://a.com/p.jpg')]);
    expect(controller.needsPermission, isTrue);

    executor.permissionUrls.clear();
    await controller.retry(_asset('https://a.com/p.jpg'));
    expect(controller.statusOf('https://a.com/p.jpg'), DownloadStatus.done);
    expect(controller.needsPermission, isFalse);
  });

  test('忙碌中重复调用直接返回，不重复入队', () async {
    final executor = FakeDownloadExecutor();
    final controller = DownloadController(executor: executor, blobSink: FakeBlobSink());

    final first = controller.downloadAll([_asset('https://a.com/1.jpg')]);
    final second = controller.downloadAll([_asset('https://a.com/2.jpg')]);
    await Future.wait([first, second]);

    expect(executor.calls, ['https://a.com/1.jpg']);
  });

  test('blob 分块转发给 sink', () async {
    final sink = FakeBlobSink();
    final controller = DownloadController(executor: FakeDownloadExecutor(), blobSink: sink);

    await controller.acceptBlobChunk(const BlobChunk(id: 'dl-1', seq: 0, data: '', last: true));

    expect(sink.chunks.length, 1);
    expect(sink.chunks.single.id, 'dl-1');
  });

  test('openPermissionSettings 透传到执行器', () async {
    final executor = FakeDownloadExecutor();
    final controller = DownloadController(executor: executor, blobSink: FakeBlobSink());

    await controller.openPermissionSettings();

    expect(executor.permissionSettingsOpened, isTrue);
  });
}
```

- [ ] **Step 7: 运行确认通过**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/features/download/download_controller_test.dart`

Expected: `All tests passed!`

- [ ] **Step 8: 静态分析**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter analyze`

Expected: `No issues found!`

- [ ] **Step 9: 提交**

```bash
git add lib/features/download test/features/download test/support
git commit -m "feat(download): blob 首选 + 原生降级下载通道与串行下载队列"
```

**Task 12 交办三条兜底的落地结果（实施后补记）：**

1. **字节数比对——不做字面实现（已裁定）**。原假设「`fetchAsBase64` 的 `call` 返回值带 `length`」不成立：`JsChannel.call` 签名是 `Future<void>`，`WebViewJsChannel` 用 `evaluateJavascript` 且丢弃返回值、不等待页面 Promise。截断检测改由三条机制覆盖：`BlobFileWriter.add` 严格校验 seq 连续（缺块/重块/乱序抛 `StateError`）→ `accept` 立刻转 `BlobFetchException` 快速降级（不必等超时）→ 末块始终不到达由 45s 超时兜底。残留缺口：JS 侧 `arrayBuffer()` 静默变短却仍置 `last=true` 的情形，seq 与超时都拦不住（要检出需扩展桥协议携带 total），一期接受。
2. **`BlobChunk.error` 非空不得进 `writer.add`**：按计划实现（先判 `error` 走失败分支）。
3. **接收器内部 try/catch**：`accept` 不得向外抛异常（`onBlobChunk` 不 await，异常会漏给平台通道）。

**编码期发现的额外修正（已并入 Task 14 提交）：**

- **分块接收串行化（必须）**：`accept` 是 fire-and-forget，而 `BlobFileWriter.add` 的 `_expectedSeq++` 在 `await writeFrom` **之后** → 「上一块还在落盘、下一块已到」会被误判乱序；更糟的是此时 `_reset()` 的 `close()` 会因「async operation pending」抛 `FileSystemException`，`completer` 永不完成。修法：`WebViewBlobFetcher` 内用 `_queue = _queue.then((_) => _handle(chunk))` 串行化，链尾 `catchError` 兜底，链**跨轮复用不重置**（残留分块靠 `writer == null || chunk.id != _activeId` 丢弃，重置会让新旧两轮重新并发）。
- **失败路径清理临时文件（必须）**：`DownloadService.download` 把「取数 → 保存」包 `try/finally` 删除 `tempFile`，否则相册权限被拒等失败路径会在临时目录持续堆积；`finally` 在 `save` 之后执行，语义不变。
- **收窄降级条件（必须）**：`catch (_)` → `on BlobFetchException catch (_)`，`writer.open()` 抛的 `FileSystemException`（临时目录不可写）不再被降级掩盖成「原生直下失败」。
- **新增测试**：`test/features/download/webview_blob_fetcher_test.dart`（5 条：正常序列、error 分块、乱序、无进行中下载时静默返回、连续两块不 await 直接连发不被误判）、`test/features/download/download_service_test.dart`（4 条：blob 成功 / 降级成功 / 两端失败 / 系统级异常不降级）。
- **`native_fetcher.dart`**：删除 `validateStatus` 之后不可达的 `if (status >= 400) throw`。
- **`download_controller_test.dart`**：删掉计划顶部那行未使用的 `import '.../download_service.dart'`（否则 `flutter analyze` 报 `unused_import`）。

---

## Task 15: 图片面板（网格 + 筛选栏 + 多选 + 操作栏）

**Files:**
- Create: `lib/features/gallery/image_panel.dart`、`lib/features/gallery/filter_bar.dart`、`lib/features/gallery/image_grid.dart`
- Test: `test/features/gallery/image_panel_test.dart`

- [ ] **Step 1: 写失败的测试**

`test/features/gallery/image_panel_test.dart`：

```dart
import 'package:download_image/core/bridge/bridge_protocol.dart';
import 'package:download_image/core/model/image_asset.dart';
import 'package:download_image/features/capture/capture_controller.dart';
import 'package:download_image/features/gallery/image_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_download.dart';

void main() {
  CaptureController controllerWith(List<ImageAsset> assets) {
    final controller = CaptureController();
    for (final asset in assets) {
      controller.accept(CaptureBatch(pageUrl: 'https://a.com/p', assets: [asset]));
    }
    return controller;
  }

  Widget wrap(CaptureController capture, {double width = 420}) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          height: 700,
          child: ImagePanel(
            capture: capture,
            download: fakeDownloadController(),
            onOpenPreview: (_) {},
          ),
        ),
      ),
    );
  }

  testWidgets('空列表显示扫描提示', (tester) async {
    await tester.pumpWidget(wrap(controllerWith(const [])));
    expect(find.byKey(const Key('panel-empty')), findsOneWidget);
  });

  testWidgets('渲染每个可见图片的图块', (tester) async {
    await tester.pumpWidget(wrap(controllerWith(const [
      ImageAsset(url: 'https://a.com/a.jpg', width: 300, height: 300),
      ImageAsset(url: 'https://a.com/b.png', width: 300, height: 300),
    ])));
    await tester.pump();

    expect(find.byKey(const Key('tile-https://a.com/a.jpg')), findsOneWidget);
    expect(find.byKey(const Key('tile-https://a.com/b.png')), findsOneWidget);
  });

  testWidgets('点选图块切换选中态，操作栏显示已选数量', (tester) async {
    final capture = controllerWith(const [
      ImageAsset(url: 'https://a.com/a.jpg', width: 300, height: 300),
      ImageAsset(url: 'https://a.com/b.png', width: 300, height: 300),
    ]);
    await tester.pumpWidget(wrap(capture));
    await tester.pump();

    expect(find.text('已选 0 张'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tile-https://a.com/a.jpg')));
    await tester.pump();
    expect(capture.selectedUrls, {'https://a.com/a.jpg'});
    expect(find.text('已选 1 张'), findsOneWidget);

    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(capture.selectedUrls.length, 2);
    expect(find.text('已选 2 张'), findsOneWidget);
  });

  testWidgets('拖动最小边滑块会即时过滤列表', (tester) async {
    final capture = controllerWith(const [
      ImageAsset(url: 'https://a.com/small.jpg', width: 80, height: 80),
      ImageAsset(url: 'https://a.com/big.jpg', width: 400, height: 400),
    ]);
    await tester.pumpWidget(wrap(capture));
    await tester.pump();
    expect(find.byKey(const Key('tile-https://a.com/small.jpg')), findsOneWidget);

    capture.setMinSide(200);
    await tester.pump();
    expect(find.byKey(const Key('tile-https://a.com/small.jpg')), findsNothing);
    expect(find.byKey(const Key('tile-https://a.com/big.jpg')), findsOneWidget);
  });

  testWidgets('格式 chip 可切换', (tester) async {
    final capture = controllerWith(const [
      ImageAsset(url: 'https://a.com/a.jpg', width: 300, height: 300),
      ImageAsset(url: 'https://a.com/b.png', width: 300, height: 300),
    ]);
    await tester.pumpWidget(wrap(capture));
    await tester.pump();

    await tester.tap(find.byKey(const Key('format-chip-jpg')));
    await tester.pump();
    expect(capture.filter.enabledFormats, {'png', 'gif', 'webp', 'svg'});
    expect(find.byKey(const Key('tile-https://a.com/a.jpg')), findsNothing);
  });

  testWidgets('来源 chip 可切换', (tester) async {
    final capture = controllerWith(const [
      ImageAsset(url: 'https://a.com/a.jpg', width: 300, height: 300, source: ImageSource.img),
      ImageAsset(url: 'https://a.com/bg.jpg', width: 300, height: 300, source: ImageSource.cssBackground),
    ]);
    await tester.pumpWidget(wrap(capture));
    await tester.pump();

    await tester.tap(find.byKey(const Key('source-chip-img')));
    await tester.pump();
    expect(find.byKey(const Key('tile-https://a.com/a.jpg')), findsNothing);
    expect(find.byKey(const Key('tile-https://a.com/bg.jpg')), findsOneWidget);
  });

  testWidgets('去重开关可切换', (tester) async {
    final capture = controllerWith(const [
      ImageAsset(url: 'https://a.com/i.jpg?w=300', width: 300, height: 300),
      ImageAsset(url: 'https://a.com/i.jpg?w=900', width: 900, height: 900),
    ]);
    await tester.pumpWidget(wrap(capture));
    await tester.pump();
    expect(find.byKey(const Key('tile-https://a.com/i.jpg?w=900')), findsOneWidget);
    expect(find.byKey(const Key('tile-https://a.com/i.jpg?w=300')), findsNothing);

    await tester.tap(find.byKey(const Key('dedupe-switch')));
    await tester.pump();
    expect(capture.filter.mergeVariants, isFalse);
    expect(find.byKey(const Key('tile-https://a.com/i.jpg?w=300')), findsOneWidget);
  });

  testWidgets('尺寸未知的图块显示未知角标', (tester) async {
    final capture = controllerWith(const [
      ImageAsset(url: 'https://a.com/unknown.jpg'),
    ]);
    await tester.pumpWidget(wrap(capture));
    await tester.pump();
    expect(find.byKey(const Key('tile-badge-unknown-https://a.com/unknown.jpg')), findsOneWidget);
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/features/gallery/image_panel_test.dart`

Expected: FAIL，`Undefined name 'ImagePanel'`。

- [ ] **Step 3: 实现筛选栏**

`lib/features/gallery/filter_bar.dart`：

```dart
import 'package:flutter/material.dart';

import '../../core/model/image_asset.dart';
import '../capture/capture_controller.dart';

const Map<ImageSource, String> kSourceLabels = {
  ImageSource.img: '<img>',
  ImageSource.srcset: 'srcset',
  ImageSource.cssBackground: 'CSS 背景图',
  ImageSource.dynamic: '动态加载',
};

class FilterBar extends StatelessWidget {
  const FilterBar({super.key, required this.capture});

  final CaptureController capture;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: capture,
      builder: (context, _) {
        final filter = capture.filter;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 180,
                  child: Row(
                    children: [
                      Text('最小边', style: Theme.of(context).textTheme.bodySmall),
                      Expanded(
                        child: Slider(
                          key: const Key('min-side-slider'),
                          value: filter.minSide.clamp(0, 512).toDouble(),
                          max: 512,
                          divisions: 16,
                          label: '${filter.minSide}px',
                          onChanged: (value) => capture.setMinSide(value.round()),
                        ),
                      ),
                      Text('${filter.minSide}px', style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                for (final format in kAllFormats)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: FilterChip(
                      key: Key('format-chip-$format'),
                      label: Text(format.toUpperCase()),
                      selected: filter.enabledFormats.contains(format),
                      onSelected: (_) => capture.toggleFormat(format),
                    ),
                  ),
                const SizedBox(width: 8),
                for (final entry in kSourceLabels.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: FilterChip(
                      key: Key('source-chip-${entry.key.name}'),
                      label: Text(entry.value),
                      selected: filter.enabledSources.contains(entry.key),
                      onSelected: (_) => capture.toggleSource(entry.key),
                    ),
                  ),
                const SizedBox(width: 8),
                Row(
                  children: [
                    Text('尺寸去重', style: Theme.of(context).textTheme.bodySmall),
                    Switch(
                      key: const Key('dedupe-switch'),
                      value: filter.mergeVariants,
                      onChanged: capture.setMergeVariants,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
```

- [ ] **Step 4: 实现网格**

`lib/features/gallery/image_grid.dart`：

```dart
import 'package:flutter/material.dart';

import '../../core/model/image_asset.dart';
import '../capture/capture_controller.dart';
import '../capture/image_filter.dart';

/// 缩略图最大边长（px），列数由面板宽度自然推导：
/// 360dp → 3 列，600dp → 5 列，960dp → 8 列。
const double kTileMaxExtent = 120;

class ImageGrid extends StatelessWidget {
  const ImageGrid({
    super.key,
    required this.assets,
    required this.capture,
    required this.pageUrl,
    required this.onOpenPreview,
  });

  final List<ImageAsset> assets;
  final CaptureController capture;
  final String? pageUrl;
  final void Function(ImageAsset asset) onOpenPreview;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(6),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: kTileMaxExtent,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
        childAspectRatio: 1,
      ),
      itemCount: assets.length,
      itemBuilder: (context, index) => _ImageTile(
        asset: assets[index],
        selected: capture.selectedUrls.contains(assets[index].url),
        pageUrl: pageUrl,
        onTap: () => capture.toggleSelection(assets[index].url),
        onLongPress: () => onOpenPreview(assets[index]),
        onPreview: () => onOpenPreview(assets[index]),
      ),
    );
  }
}

class _ImageTile extends StatelessWidget {
  const _ImageTile({
    required this.asset,
    required this.selected,
    required this.pageUrl,
    required this.onTap,
    required this.onLongPress,
    required this.onPreview,
  });

  final ImageAsset asset;
  final bool selected;
  final String? pageUrl;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final format = formatOf(asset);
    final badge = asset.sizeKnown ? '${asset.width}×${asset.height}' : '尺寸未知';
    return InkWell(
      key: Key('tile-${asset.url}'),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: selected ? Theme.of(context).colorScheme.primary : Colors.black12,
                width: selected ? 2 : 1,
              ),
            ),
            child: Image.network(
              asset.url,
              fit: BoxFit.cover,
              headers: pageUrl == null ? null : {'Referer': pageUrl!, 'Accept': 'image/*,*/*;q=0.8'},
              errorBuilder: (context, error, stack) => const Center(
                child: Icon(Icons.broken_image_outlined, key: Key('tile-thumb-error')),
              ),
            ),
          ),
          Positioned(
            left: 2,
            bottom: 2,
            child: Text(
              format == null ? badge : '$badge · ${format.toUpperCase()}',
              key: asset.sizeKnown
                  ? Key('tile-badge-${asset.url}')
                  : Key('tile-badge-unknown-${asset.url}'),
              style: const TextStyle(fontSize: 9, color: Colors.white, backgroundColor: Colors.black54),
            ),
          ),
          Positioned(
            right: 2,
            top: 2,
            child: InkWell(
              key: Key('tile-preview-${asset.url}'),
              onTap: onPreview,
              child: Icon(
                Icons.zoom_in,
                size: 16,
                color: Colors.white.withValues(alpha: 0.9),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 5: 实现面板与操作栏**

`lib/features/gallery/image_panel.dart`：

```dart
import 'package:flutter/material.dart';

import '../../core/model/image_asset.dart';
import '../capture/capture_controller.dart';
import '../download/download_controller.dart';
import 'filter_bar.dart';
import 'image_grid.dart';

/// 图片面板：筛选栏 + 网格 + 底部操作栏。桌面右栏与移动端 BottomSheet 共用。
class ImagePanel extends StatelessWidget {
  const ImagePanel({
    super.key,
    required this.capture,
    required this.download,
    required this.onOpenPreview,
    this.onPermissionDenied,
  });

  final CaptureController capture;
  final DownloadController download;
  final void Function(ImageAsset asset) onOpenPreview;

  /// 下载因相册权限被拒时由外层弹引导。
  final VoidCallback? onPermissionDenied;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([capture, download]),
      builder: (context, _) {
        final assets = capture.visibleAssets;
        return Column(
          key: const Key('image-panel'),
          children: [
            FilterBar(capture: capture),
            const Divider(height: 1),
            Expanded(
              child: assets.isEmpty
                  ? _EmptyHint(capture: capture)
                  : ImageGrid(
                      assets: assets,
                      capture: capture,
                      pageUrl: capture.pageUrl,
                      onOpenPreview: onOpenPreview,
                    ),
            ),
            const Divider(height: 1),
            _ActionBar(capture: capture, download: download, onPermissionDenied: onPermissionDenied),
          ],
        );
      },
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.capture});

  final CaptureController capture;

  @override
  Widget build(BuildContext context) {
    final text = capture.isScanning ? '正在扫描页面图片…' : '未发现符合条件的图片，可调整筛选或重新扫描';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, key: const Key('panel-empty'), textAlign: TextAlign.center),
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.capture, required this.download, this.onPermissionDenied});

  final CaptureController capture;
  final DownloadController download;
  final VoidCallback? onPermissionDenied;

  @override
  Widget build(BuildContext context) {
    final selected = capture.selectedAssets;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          TextButton(
            key: const Key('select-all'),
            onPressed: capture.selectAllVisible,
            child: const Text('全选'),
          ),
          TextButton(
            key: const Key('select-none'),
            onPressed: capture.clearSelection,
            child: const Text('清空选择'),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              download.isBusy ? download.progressLabel : '已选 ${selected.length} 张',
              key: const Key('selection-label'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          FilledButton.icon(
            key: const Key('download-selected'),
            onPressed: download.isBusy || selected.isEmpty
                ? null
                : () async {
                    await download.downloadAll(selected);
                    if (download.needsPermission) onPermissionDenied?.call();
                  },
            icon: const Icon(Icons.download),
            label: const Text('下载'),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 6: 运行确认通过**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/features/gallery/image_panel_test.dart`

Expected: `All tests passed!`

- [ ] **Step 7: 提交**

```bash
git add lib/features/gallery test/features/gallery
git commit -m "feat(gallery): 图片面板（筛选栏、自适应网格、多选、下载操作栏）"
```

**补记（Task 15 实施结果）**：已完成，分三次提交：`31cee8e`（实现）、`d09afba`（审查修复）、`5296f27`（性能补修）。全量 105 条用例全绿，`analyze` 无问题；规格审查与代码质量审查均通过。

- **`visibleAssets` 缓存评估结论：不加缓存**。全量过滤+去重是 O(n) 线性（主要成本是 `variantKey` 里的 `Uri.tryParse`），且扫描期通知频率低（每屏 2 次、MutationObserver 300ms 节流），加缓存只换来失效风险。真正的问题是**重复计算**，已消除。
- 相对计划代码的必要修正（均已复审确认）：
  - `filter_bar.dart` 补 `import '../capture/image_filter.dart'`（计划漏写，`kAllFormats` 定义在此）。
  - 测试 import 改 `../../support/fake_download.dart`；位于横向滚动区屏外的控件仍需 `ensureVisible`（来源 chip 在 420dp 下仍要滚动才可见）。
  - 面板把 `visibleAssets` 快照与选中集**各只取一次**再逐层传递（`_ActionBar.selected`、`ImageGrid.selectedUrls`）。注意 `capture.selectedUrls` 返回 `Set.unmodifiable`，是**深拷贝**，写进循环条件会变成 O(N×S)（全选 3000 张实测 ≈14ms/帧）。
  - 网格 `Image.network` 加 `cacheWidth/cacheHeight = kTileMaxExtent × devicePixelRatio`，避免缩略图按原分辨率解码撑爆 `ImageCache`。
  - 筛选栏把「尺寸去重」开关前移到首位（420dp 首屏可见，已加位置断言防回归）；滑块用例改为真实 `tapAt` 分度，不再直接调 controller。
  - 预览按钮由 16×16 的 `InkWell` 改为 `IconButton`（`iconSize:16` + `tightFor(32,32)` + `tapTargetSize: MaterialTapTargetSize.shrinkWrap`）。**`shrinkWrap` 不可省**：Material 3 默认 `padded` 会把命中区撑到 48×48，420dp 面板下会盖住 tile 中心并抢走点选手势（两条既有用例即变红）。
- 已知取舍（本期不改，Task 17/18 留意）：SVG 缩略图必然破图（未引入 `flutter_svg`，`Image.network` 解不了 SVG，与「加载失败」占位混同）；切页「保留」后旧页实例仍以当前 `pageUrl` 作 Referer，可能 403；预览按钮 32dp 低于 48dp 可达性建议值；`isBusy` 进度文案、长按预览、「选中后被筛掉的图不进下载」暂无用例。

---

## Task 16: 大图预览与复制直链

**Files:**
- Create: `lib/features/gallery/image_preview_page.dart`

- [ ] **Step 1: 实现预览页**

`lib/features/gallery/image_preview_page.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/model/image_asset.dart';
import '../capture/image_filter.dart';

class ImagePreviewPage extends StatelessWidget {
  const ImagePreviewPage({
    super.key,
    required this.asset,
    required this.pageUrl,
    required this.onDownload,
  });

  final ImageAsset asset;
  final String? pageUrl;
  final Future<void> Function(ImageAsset asset) onDownload;

  @override
  Widget build(BuildContext context) {
    final format = formatOf(asset);
    final size = asset.sizeKnown ? '${asset.width}×${asset.height}' : '尺寸未知';
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('$size${format == null ? '' : ' · ${format.toUpperCase()}'}'),
      ),
      body: InteractiveViewer(
        minScale: 0.5,
        maxScale: 6,
        child: Center(
          child: Image.network(
            asset.url,
            headers: pageUrl == null ? null : {'Referer': pageUrl!, 'Accept': 'image/*,*/*;q=0.8'},
            errorBuilder: (context, error, stack) => const Text(
              '图片无法预览（可能需要防盗链校验）',
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('preview-copy-link'),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: asset.url));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('直链已复制')),
                      );
                    }
                  },
                  icon: const Icon(Icons.link),
                  label: const Text('复制直链'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  key: const Key('preview-download'),
                  onPressed: () => onDownload(asset),
                  icon: const Icon(Icons.download),
                  label: const Text('下载这张'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: 静态分析**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter analyze`

Expected: `No issues found!`

- [ ] **Step 3: 提交**

```bash
git add lib/features/gallery/image_preview_page.dart
git commit -m "feat(gallery): 大图预览与复制直链"
```

**补记（Task 16 实施结果）**：已完成，提交 `caba7f4`（实现 + 测试）、`e955dd3`（补加载失败路径用例）。全量 110 条用例全绿，`analyze` 无问题；规格审查与代码质量审查均通过。计划本步未要求写测试，按项目 TDD 惯例补了 5 条（标题尺寸/格式、尺寸未知、复制直链写入剪贴板并提示、下载回调、加载失败提示）；页内代码与计划逐字一致，唯一偏离是 `git add` 显式加了测试文件路径。

- **交办 Task 17（必须落实）**：`onDownload` 契约（`Future<void> Function(ImageAsset)`）**表达不了失败**——`DownloadController.downloadAll` 内部 catch 掉所有异常、只写 `_status`/`_errors`，**从不抛出**。所以「下载这张」在**非权限类失败**（镜像 403、写盘失败等）下用户完全没有反馈。Task 17 的 wrapper 除了 `needsPermission` 弹权限引导外，还应在 await 之后读 `download.errorOf(asset.url)` 并给出提示（面板侧同一缺口，一并处理）。
- 另需 Task 17 决定：预览页按钮不受 `download.isBusy` 约束，连点第二次会被 `downloadAll` 的 `_busy` 早退，wrapper 可能读到**上一批**的 `needsPermission` 而重复弹权限引导。
- 已知取舍（本期不改）：预览页按**原分辨率**解码（保证放大清晰），极端大图（如 12000×8000）单张解码可达数百 MB，移动端有 OOM 风险；`Referer`/`Accept` headers 与尺寸角标文案在预览页与网格各写一份，抽取为非必须。

---

## Task 17: 应用壳、900dp 断点与四端启动检查

**Files:**
- Create: `lib/app/app.dart`、`lib/app/home_shell.dart`、`lib/app/breakpoints.dart`、`lib/features/browser/platform/webview2_check.dart`
- Modify: `lib/main.dart`（替换 Task 2 的临时入口）
- Test: `test/app/home_shell_test.dart`

- [ ] **Step 1: 写断点常量的失败测试**

`test/app/home_shell_test.dart`：

```dart
import 'package:download_image/app/breakpoints.dart';
import 'package:download_image/app/home_shell.dart';
import 'package:download_image/features/capture/capture_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('断点为 900dp', () {
    expect(kPanelBreakpoint, 900);
  });

  testWidgets('≥900dp：左右分栏，图片面板常驻', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: HomeShell(browserContentOverride: const SizedBox.expand()),
    ));

    expect(find.byKey(const Key('panel-docked')), findsOneWidget);
    expect(find.byKey(const Key('capture-fab')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('<900dp：WebView 全屏 + 浮动按钮，点开为 BottomSheet', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: HomeShell(browserContentOverride: const SizedBox.expand()),
    ));

    expect(find.byKey(const Key('panel-docked')), findsNothing);
    expect(find.byKey(const Key('capture-fab')), findsOneWidget);
    expect(find.textContaining('已捕获'), findsOneWidget);

    await tester.tap(find.byKey(const Key('capture-fab')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('image-panel')), findsOneWidget);
  });

  testWidgets('折叠按钮在宽屏下隐藏面板', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: HomeShell(browserContentOverride: const SizedBox.expand()),
    ));

    await tester.tap(find.byKey(const Key('panel-collapse')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('image-panel')), findsNothing);
    expect(find.byKey(const Key('panel-expand')), findsOneWidget);
  });

  testWidgets('已捕获数量用 CaptureController 的真实数据', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final capture = CaptureController();
    capture.accept(CaptureBatch(pageUrl: 'https://a.com/p', assets: const [
      ImageAsset(url: 'https://a.com/a.jpg', width: 300, height: 300),
    ]));

    await tester.pumpWidget(MaterialApp(
      home: HomeShell(browserContentOverride: const SizedBox.expand(), capture: capture),
    ));

    expect(find.text('已捕获 1 张'), findsOneWidget);
  });
}
```

注意：上面测试里的 `CaptureBatch` / `ImageAsset` 需要 `import 'package:download_image/core/bridge/bridge_protocol.dart';` 与 `import 'package:download_image/core/model/image_asset.dart';`，写测试时补上。

- [ ] **Step 2: 运行确认失败**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/app/home_shell_test.dart`

Expected: FAIL，`Undefined name 'kPanelBreakpoint'`。

- [ ] **Step 3: 实现断点与应用壳**

`lib/app/breakpoints.dart`：

```dart
/// 布局断点（dp）：≥ 此宽度用左右分栏，否则用全屏 + BottomSheet。
const double kPanelBreakpoint = 900;

/// 图片面板最小宽度。
const double kPanelMinWidth = 280;

/// 图片面板最大宽度。
const double kPanelMaxWidth = 720;
```

`lib/app/app.dart`：

```dart
import 'package:flutter/material.dart';

import 'home_shell.dart';

class ImageCaptureApp extends StatelessWidget {
  const ImageCaptureApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '网页图片抓取下载器',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const HomeShell(),
    );
  }
}
```

- [ ] **Step 4: 实现 HomeShell**

`lib/app/home_shell.dart`：

```dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../core/bridge/js_channel.dart';
import '../features/browser/browser_controller.dart';
import '../features/browser/browser_page.dart';
import '../features/capture/capture_controller.dart';
import '../features/capture/capture_script.dart';
import '../features/download/download_controller.dart';
import '../features/download/download_service.dart';
import '../features/download/save_target.dart';
import '../features/download/webview_blob_fetcher.dart';
import '../features/gallery/image_panel.dart';
import '../features/gallery/image_preview_page.dart';
import 'breakpoints.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    this.capture,
    this.browser,
    this.download,
    this.initialUrl,
    this.browserContentOverride,
  });

  final CaptureController? capture;
  final BrowserController? browser;
  final DownloadController? download;
  final Uri? initialUrl;

  /// 仅测试使用：替换真实 WebView。
  final Widget? browserContentOverride;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late final CaptureController _capture;
  late final BrowserController _browser;
  late final DownloadController _download;
  final JsChannelHolder _jsChannel = JsChannelHolder();

  double _panelWidth = 420;
  bool _panelCollapsed = false;

  static final Uri _fallbackUrl = Uri.parse('https://example.com');

  @override
  void initState() {
    super.initState();
    _capture = widget.capture ?? CaptureController();
    _browser = widget.browser ?? BrowserController();
    final blobFetcher = WebViewBlobFetcher(_jsChannel);
    _download = widget.download ??
        DownloadController(
          executor: DownloadService(
            blobFetcher: blobFetcher,
            saveTarget: createSaveTarget(),
            refererProvider: () => _capture.pageUrl,
          ),
          blobSink: blobFetcher,
        );
  }

  /// 两个参数都来自 BrowserPage 传进来的快照：`previousUrl` 是切换前的主框架
  /// URL。不要在这里读 `_capture.pageUrl` —— 新页的抓取消息通常已经把它覆写了。
  Future<PageSwitchDecision> _askPageSwitch(String previousUrl, String newPageUrl) async {
    final decision = await showDialog<PageSwitchDecision>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('页面已切换'),
        content: Text('已从 $previousUrl 切换到 $newPageUrl。\n是否清空上一个页面抓到的图片？\n'
            '（只清空该页抓到的图，新页面已抓到的会保留）'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, PageSwitchDecision.keep),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, PageSwitchDecision.clear),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    return decision ?? PageSwitchDecision.keep;
  }

  Future<void> _openPreview(ImageAsset asset) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (context) => ImagePreviewPage(
        asset: asset,
        pageUrl: _capture.pageUrl,
        onDownload: (target) async {
          await _download.downloadAll([target]);
          if (mounted && _download.needsPermission) await _showPermissionGuide();
        },
      ),
    ));
  }

  Future<void> _showPermissionGuide() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('没有相册写入权限'),
        content: const Text('请在系统设置中允许本应用写入相册，然后回到应用重试。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('稍后')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('去设置')),
        ],
      ),
    );
    if (go == true) {
      await _download.openPermissionSettings();
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= kPanelBreakpoint;
    return Scaffold(
      body: SafeArea(
        child: isWide
            ? Row(
                children: [
                  Expanded(child: _buildBrowser()),
                  if (!_panelCollapsed) ...[
                    _DragHandle(
                      onDrag: (delta) => setState(() {
                        _panelWidth = (_panelWidth - delta).clamp(kPanelMinWidth, kPanelMaxWidth);
                      }),
                    ),
                    SizedBox(
                      width: _panelWidth,
                      child: KeyedSubtree(key: const Key('panel-docked'), child: _buildPanel()),
                    ),
                  ],
                ],
              )
            : _buildBrowser(),
      ),
      floatingActionButton: isWide
          ? (_panelCollapsed
              ? FloatingActionButton(
                  key: const Key('panel-expand'),
                  onPressed: () => setState(() => _panelCollapsed = false),
                  child: const Icon(Icons.photo_library),
                )
              : null)
          : ListenableBuilder(
              listenable: _capture,
              builder: (context, _) => FloatingActionButton.extended(
                key: const Key('capture-fab'),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (context) => SizedBox(
                    height: MediaQuery.sizeOf(context).height * 0.85,
                    child: _buildPanel(),
                  ),
                ),
                icon: const Icon(Icons.photo_library),
                label: Text(
                  _download.isBusy ? _download.progressLabel : '已捕获 ${_capture.visibleAssets.length} 张',
                ),
              ),
            ),
    );
  }

  Widget _buildPanel() => ImagePanel(
        capture: _capture,
        download: _download,
        onOpenPreview: _openPreview,
        onPermissionDenied: _showPermissionGuide,
      );

  Widget _buildBrowser() => BrowserPage(
        initialUrl: widget.initialUrl ?? _fallbackUrl,
        browser: _browser,
        capture: _capture,
        jsChannel: _jsChannel,
        onTapCaptureCount: () {},
        onPageSwitchNeeded: _askPageSwitch,
        onBlobChunk: (chunk) => unawaited(_download.acceptBlobChunk(chunk)),
        onScanLimitReached: () => _showSnack('已达扫描上限，可手动继续滚动后再次扫描'),
        contentOverride: widget.browserContentOverride,
      );

  @override
  void dispose() {
    _jsChannel.detach();
    super.dispose();
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle({required this.onDrag});

  final void Function(double delta) onDrag;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('panel-drag-handle'),
      onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: Container(width: 8, color: Theme.of(context).dividerColor),
      ),
    );
  }
}
```

同时给 `HomeShell` 的宽屏布局补上折叠按钮（`Key('panel-collapse')`），加到浏览器栏顶部：

```dart
/// 放在 _buildBrowser() 外面、Row 的第一个子节点位置（仅宽屏显示）：
if (isWide && !_panelCollapsed)
  Align(
    alignment: Alignment.topRight,
    child: IconButton(
      key: const Key('panel-collapse'),
      tooltip: '折叠图片面板',
      onPressed: () => setState(() => _panelCollapsed = true),
      icon: const Icon(Icons.view_sidebar),
    ),
  ),
```

- [ ] **Step 5: 修「切换页面清空」会连新页资产一起删（Task 11 ⚠️ 段的三件事，必须一起做）**

背景见 Task 11 末尾的 ⚠️ 段：确认对话框在**新页加载完之后**才弹，新页的图往往已经在列表里，此时 `capture.clear()` 会把它们一并抹掉，而 `flush()` 只推增量、后续 `scan()` 也不会重推 → 静默丢图。

5.1 给 `CaptureController` 加一个只删指定 URL 的方法（追加到 `clear()` 上方）：

```dart
  /// 只删这几个 URL（切换页面时用户选择「清空」）。
  ///
  /// 不用 clear()：新页 DOM 解析后约 300ms 抓取脚本就会推一批图，等用户在对话框上
  /// 点「清空」时新页的图已经在 _byUrl 里了，一把清光会静默丢图。
  void removeUrls(Iterable<String> urls) {
    var changed = false;
    for (final url in urls) {
      if (_byUrl.remove(url) != null) changed = true;
      _selected.remove(url);
    }
    if (changed) notifyListeners();
  }
```

5.2 给 `CaptureController` 补一条测试（追加到 `test/features/capture/capture_controller_test.dart`）：

```dart
  test('removeUrls 只删指定 URL，新页资产与扫描状态不受影响', () {
    final controller = CaptureController();
    controller
      ..accept(CaptureBatch(pageUrl: 'https://a.com/p', assets: [
        ImageAsset(url: 'https://a.com/1.png', source: AssetSource.img),
      ]))
      ..toggleSelection('https://a.com/1.png')
      // 新页的图（模拟：对话框弹出时已经抓到了）
      ..accept(CaptureBatch(pageUrl: 'https://b.com/p', assets: [
        ImageAsset(url: 'https://b.com/2.png', source: AssetSource.img),
      ]))
      ..removeUrls(['https://a.com/1.png']);

    expect(controller.rawAssets.map((a) => a.url), ['https://b.com/2.png']);
    expect(controller.selectedUrls, isEmpty, reason: '被删掉的 URL 也要退出选中态');
    expect(controller.pageUrl, 'https://b.com/p', reason: '不该动页面 URL');
  });
```

（`ImageAsset` 的必填参数以 `lib/core/model/image_asset.dart` 的构造函数为准，上面的 `source:` 若与此前用例写法不一致就照抄既有用例。）

5.3 `lib/features/browser/browser_page.dart` 改三处：

```dart
  /// 主框架开始导航前那一批资产的 URL 快照。对话框弹出时新页的图可能已经进来了，
  /// 「清空」只该清掉这些。
  Set<String> _urlsBeforeNavigation = const {};
```

```dart
      onLoadStart: (controller, url) {
        // 只在确实是「换页」时快照，刷新同一页不重置（否则对话框来不及弹就先被清）。
        final target = url?.toString();
        if (target != null && target != _lastMainFrameUrl) {
          _urlsBeforeNavigation = widget.capture.rawAssets.map((a) => a.url).toSet();
        }
        widget.browser.updateLoading(loading: true, progress: 0);
      },
```

`_afterMainFrameLoad` 的 clear 分支：

```dart
      } else {
        // 只删上一个页面的资产，别把新页已经推过来的图也清掉（见 Task 11 ⚠️ 段）。
        if (_urlsBeforeNavigation.isEmpty) {
          capture.clear();
        } else {
          capture.removeUrls(_urlsBeforeNavigation);
        }
        _urlsBeforeNavigation = const {};
      }
```

并且把回调改成带 `previousUrl` 的签名（更新 `_lastMainFrameUrl` **之前**取旧值）：

```dart
    final previousUrl = _lastMainFrameUrl;
    final isNewPage = previousUrl != null && previousUrl != url;
    _lastMainFrameUrl = url;
    if (isNewPage) {
      _autoScannedForCurrentUrl = false;
      var keepAssets = true;
      if (capture.rawCount > 0) {
        keepAssets = await widget.onPageSwitchNeeded?.call(previousUrl, url) !=
            PageSwitchDecision.clear;
      }
      // …keep/else 分支同前
    }
```

`onPageSwitchNeeded` 字段类型同步改为：

```dart
  final Future<PageSwitchDecision> Function(String previousUrl, String newUrl)? onPageSwitchNeeded;
```

5.4 跑测试确认没回归：`/Users/ling/fvm/versions/3.47.4/bin/flutter test`。

- [ ] **Step 6: 实现 Windows WebView2 检测**

`lib/features/browser/platform/webview2_check.dart`：

```dart
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Windows 上未安装 WebView2 Runtime 时返回 true（其他平台恒为 false）。
/// 若 `WebViewEnvironment.getAvailableVersion` 在本版本是实例方法，改为
/// `WebViewEnvironment().getAvailableVersion()`。
Future<bool> isWebView2Missing() async {
  if (!Platform.isWindows) return false;
  try {
    final version = await WebViewEnvironment.getAvailableVersion();
    return version == null || version.isEmpty;
  } catch (_) {
    return true;
  }
}
```

- [ ] **Step 7: 替换入口**

`lib/main.dart`：

```dart
import 'package:flutter/material.dart';

import 'app/app.dart';
import 'features/browser/platform/webview2_check.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (await isWebView2Missing()) {
    runApp(const _WebView2MissingApp());
    return;
  }
  runApp(const ImageCaptureApp());
}

/// Windows 10 可能未预装 WebView2 Runtime（设计文档第 9 节）。
class _WebView2MissingApp extends StatelessWidget {
  const _WebView2MissingApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.download_for_offline_outlined, size: 56),
                SizedBox(height: 16),
                Text(
                  '缺少 WebView2 Runtime',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  '本应用依赖 Microsoft Edge WebView2 Runtime。请到 '
                  'https://developer.microsoft.com/microsoft-edge/webview2/ 下载安装后重新打开应用。',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 8: 运行测试**

Run: `/Users/ling/fvm/versions/3.47.4/bin/flutter test test/app/home_shell_test.dart`

Expected: `All tests passed!`

- [ ] **Step 9: 全量测试 + 分析**

Run:

```bash
/Users/ling/fvm/versions/3.47.4/bin/flutter analyze && /Users/ling/fvm/versions/3.47.4/bin/flutter test
```

Expected: `No issues found!` 与 `All tests passed!`

- [ ] **Step 10: 提交**

```bash
git add lib/app lib/main.dart test/app lib/features/browser/browser_page.dart \
  lib/features/capture/capture_controller.dart \
  test/features/capture/capture_controller_test.dart
git commit -m "feat(app): 应用壳、900dp 响应式布局、WebView2 缺失引导"
```

**补记（Task 17 实施结果）**：已完成，提交号「见本次提交」（单次提交）。全量 **120 条**用例全绿（基线 110 + 本次新增 10），`flutter analyze` 输出 `No issues found!`。计划 Step 1-10 与上游交办的补充项 A/B/C/D 全部落地，`lib/features/browser/platform/webview2_check.dart` 用计划原文（6.1.5 中 `WebViewEnvironment.getAvailableVersion()` 确为静态方法，无需改实例调用）。

新增用例（10 条）：计划 Step 1 的 5 条（断点常量、≥900dp 分栏、<900dp BottomSheet、折叠按钮、已捕获计数）+ 追加 5 条（`page-loading` 进度条消费 `isLoading/progress`、跨越 900dp 不重建浏览器子树、窄屏面板下载失败 SnackBar、宽屏预览页「下载这张」失败 SnackBar、`test/features/capture/capture_controller_test.dart` 的 `removeUrls`）。第 4 条（宽屏预览页失败 SnackBar）**未放弃**，在 widget 测试里稳定通过（`Image.network` 走 `errorBuilder`，`ScaffoldMessenger` 取根 messenger，失败提示可被 `find.textContaining` 命中）。

与计划原文的偏离点：
1. **折叠按钮改放 `_buildBrowser()` 内的 `Stack` 叠层**（计划原文是当 `Row` 的第一个子节点）。原因：它一旦占下标 0，下标 0 的类型会在 `Align` 与 `Expanded` 之间跳变，又把 `BrowserPage` 重建一次，`_currentUrl` 丢失。改后 `body` 恒为 `Row`、首子节点恒为 `Expanded(child: _buildBrowser())`，图片面板的 `_DragHandle` 与 `SizedBox(key: 'panel-docked')` 仅条件追加。
2. **删除死参数 `BrowserPage.onTapCaptureCount`**：字段、构造参数、文档注释全删，`HomeShell` 不再传（浮层「已捕获 N 张」由 `HomeShell` 自己渲染并直接开 BottomSheet）。全仓 `lib` 与 `test` 已无引用。
3. **新增 `page-loading` 细进度条**：插在 `_AddressBar` 与扫描状态条之间，`LinearProgressIndicator(minHeight: 2)` 消费原先无人消费的 `BrowserController.isLoading/progress`，非加载态返回 `SizedBox.shrink()`。
4. **下载失败反馈**（原计划只处理「权限被拒」）：`ImagePanel` 与内部 `_ActionBar` 各加可选回调 `onDownloadFailed`，`downloadAll` 之后先判 `needsPermission` 早退，再收集 `errorOf(url) != null` 的项回调；`HomeShell._buildPanel()` 提示文案 `'${failed.length} 张下载失败：${_download.errorOf(failed.first.url)}'`，预览页走新增的 `_downloadFromPreview`，文案 `'下载失败：$error'`。**覆盖范围**：面板「下载」在非权限类失败（镜像 403、写盘失败等）下不再「点了没反应」；`_downloadFromPreview` 开头 `if (_download.isBusy) return;`，避免连点第二次被 `downloadAll` 的 `_busy` 早退后读到上一批 `needsPermission`、重复弹权限引导。
5. **Step 5 的 C2 修复**已一并落地：`CaptureController.removeUrls`（只加这一个方法）、`BrowserPage._urlsBeforeNavigation` 快照 + clear 分支改 `removeUrls`、`onPageSwitchNeeded` 签名改为 `(String previousUrl, String newUrl)`（用更新前的 `_lastMainFrameUrl`，不读 `capture.pageUrl`）。
6. `HomeShell` 补了计划漏写的 `import '../core/model/image_asset.dart';`；计划里的 `import '../features/capture/capture_script.dart';` 未使用，未引入。`git add` 按上游交办补齐了 `webview2_check.dart`、`image_panel.dart` 与计划文件本身。

仍未处理 / 留待 Task 18：
- `_buildBrowser()` 的折叠按钮用 `Positioned(top: 4, right: 4)` 叠在浏览器右上角，宽屏下与地址栏最右的「重新扫描整页」（`scan-again`）命中区重叠，可能抢走该按钮的点击——需 Task 18 手动验收时确认，若要避开可改用 `AppBar`/独立工具栏或下调位置。
- 预览页按原分辨率解码（Task 16 已知取舍）、切换页面「保留」后旧页资产仍以当前 `pageUrl` 作 Referer、SVG 缩略图必然破图——均未在本任务处理。
- 面板 `isBusy` 进度文案、「选中后被筛掉的图不进下载」仍无用例；`removeUrls` 的扫描态复位未单测（依赖 `BrowserPage` 集成路径，留待 Task 18 端到端覆盖）。
- 四端（Windows/macOS/Linux/Android）真实启动检查未做，Task 18 手动验收阶段执行。

---

## Task 18: JS 抓取端到端测试与手动验收

**Files:**
- Create: `integration_test/js_capture_test.dart`
- Modify: 本计划文件（记录验收结果）

- [ ] **Step 1: 写 fixture 与端到端测试**

`integration_test/js_capture_test.dart`：

```dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:download_image/core/bridge/bridge_protocol.dart';
import 'package:download_image/core/bridge/js_channel.dart';
import 'package:download_image/core/model/image_asset.dart';
import 'package:download_image/features/capture/capture_controller.dart';
import 'package:download_image/features/capture/capture_script.dart';
import 'package:download_image/features/capture/image_filter.dart';
import 'package:download_image/features/download/blob_file_writer.dart';
import 'package:download_image/features/browser/webview_js_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const String _fixture = '''
<!DOCTYPE html><html><head><style>
  .bg1 { width: 200px; height: 200px; background-image: url('/img/bg-1.png'); }
  .bg2 { width: 200px; height: 200px; background-image: url('/img/bg-2.jpg'); }
</style></head><body>
  <img id="a" src="/img/a.jpg" width="300" height="200">
  <img id="b" src="/img/b.png" width="120" height="120">
  <img id="c" src="/img/c.gif" width="1" height="1">
  <picture><source srcset="/img/d-small.webp 300w, /img/d-large.webp 1200w"></picture>
  <div class="bg1"></div>
  <div class="bg2"></div>
  <div id="lazy"></div>
  <div style="height: 4000px"></div>
  <script>
    setTimeout(function () {
      var img = document.createElement('img');
      img.src = '/img/lazy-e.jpg';
      img.width = 240; img.height = 240;
      document.getElementById('lazy').appendChild(img);
    }, 200);
  </script>
</body></html>
''';

const String _fixtureUrl = 'https://fixture.local/index.html';

const Set<String> _expectedUrls = {
  'https://fixture.local/img/a.jpg',
  'https://fixture.local/img/b.png',
  'https://fixture.local/img/c.gif',
  'https://fixture.local/img/d-large.webp',
  'https://fixture.local/img/bg-1.png',
  'https://fixture.local/img/bg-2.jpg',
  'https://fixture.local/img/lazy-e.jpg',
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('抓取脚本能拿到 fixture 里全部图片 URL，且与 JS 侧一致', (tester) async {
    final capture = CaptureController();
    final scanDone = Completer<void>();
    final blobChunks = <BlobChunk>[];
    final jsChannel = JsChannelHolder();
    late InAppWebViewController controller;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(_fixtureUrl)),
          initialData: InAppWebViewInitialData(data: _fixture, baseUrl: WebUri(_fixtureUrl), mimeType: 'text/html'),
          initialUserScripts: UnmodifiableListView<UserScript>([
            UserScript(
              source: kCaptureScript,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              forMainFrameOnly: false,
            ),
          ]),
          onWebViewCreated: (created) {
            controller = created;
            jsChannel.attach(WebViewJsChannel(created));
            created.addJavaScriptHandler(
              handlerName: kBridgeHandlerName,
              callback: (args) {
                final message = BridgeMessage.parse(args.isNotEmpty ? args.first : null);
                if (message == null) return null;
                switch (message) {
                  case BlobChunk chunk:
                    blobChunks.add(chunk);
                  case ScanProgress progress:
                    if (progress.state == ScanState.done || progress.state == ScanState.limit) {
                      if (!scanDone.isCompleted) scanDone.complete();
                    }
                    capture.accept(progress);
                  case CaptureBatch batch:
                    capture.accept(batch);
                }
                return null;
              },
            );
          },
          onLoadStop: (created, url) async {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            await created.evaluateJavascript(
              source: 'window.__imgcat.scan({"maxScreens": 40, "timeoutMs": 60000});',
            );
          },
        ),
      ),
    ));

    await tester.pumpAndSettle(const Duration(seconds: 1));
    await scanDone.future.timeout(const Duration(seconds: 60));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final dartUrls = capture.rawAssets.map((asset) => asset.url).toSet();
    expect(dartUrls, _expectedUrls, reason: 'Dart 侧拿到的 URL 集合必须与 fixture 完全一致');

    final jsUrlsRaw = await controller.evaluateJavascript(source: 'JSON.stringify(window.__imgcat.assets())');
    final jsUrls = (jsUrlsRaw as List).cast<String>().toSet();
    expect(jsUrls, _expectedUrls, reason: 'JS 侧聚合集合必须与预期一致');
    expect(jsUrls, dartUrls, reason: '桥不能丢消息');

    final byUrl = {for (final asset in capture.rawAssets) asset.url: asset};
    expect(byUrl['https://fixture.local/img/d-large.webp']!.source, ImageSource.srcset);
    expect(byUrl['https://fixture.local/img/d-large.webp']!.sizeKnown, isFalse);
    expect(byUrl['https://fixture.local/img/bg-1.png']!.source, ImageSource.cssBackground);

    final visible = capture.visibleAssets;
    expect(visible.any((asset) => asset.url.endsWith('c.gif')), isFalse, reason: '1×1 像素必须被过滤');
    expect(visible.any((asset) => asset.url.endsWith('a.jpg')), isTrue);
    expect(
      visible.where((asset) => asset.url.endsWith('d-large.webp')).length,
      1,
      reason: 'srcset 只保留最大候选，小候选不能重复出现；尺寸未知的不过滤',
    );

    // 分块通道端到端：1.2MB 走 3 个分块，逐块写入临时文件后字节数一致。
    final tempDir = Directory.systemTemp.createTempSync('imgcat_it');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final destination = File('${tempDir.path}/blob.bin');
    final writer = BlobFileWriter(destination);
    await writer.open();

    final blobDone = Completer<void>();
    const totalBytes = 1200000;
    await controller.evaluateJavascript(source: '''
      (function () {
        var bytes = new Uint8Array($totalBytes);
        for (var i = 0; i < bytes.length; i++) { bytes[i] = i % 251; }
        window.__imgcatTestBlobUrl = URL.createObjectURL(new Blob([bytes], { type: 'image/png' }));
        window.__imgcat.fetchAsBase64({ url: window.__imgcatTestBlobUrl, id: 'it-1', chunkSize: $kBlobChunkBytes });
      })();
    ''');

    // 等待分块全部到达
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      final mine = blobChunks.where((chunk) => chunk.id == 'it-1').toList();
      if (mine.isNotEmpty && mine.last.last) {
        for (final chunk in mine) {
          await writer.add(chunk);
        }
        if (!blobDone.isCompleted) blobDone.complete();
        break;
      }
    }
    await blobDone.future.timeout(const Duration(seconds: 5));
    await writer.close();

    expect(await destination.length(), totalBytes);
    final bytes = await destination.readAsBytes();
    expect(bytes[0], 0);
    expect(bytes[251], 0);
    expect(bytes[250], 250);
  });
}
```

- [ ] **Step 2: 在 macOS 上跑集成测试**

Run:

```bash
/Users/ling/fvm/versions/3.47.4/bin/flutter test integration_test/js_capture_test.dart -d macos
```

Expected: `All tests passed!`

若 `d-large.webp` 没被捕获：检查 `scanImages` 里 `picture source` 的选择器与 `pickFromSrcset` 的 `w` 解析。若 `lazy-e.jpg` 没被捕获：检查 MutationObserver 的 debounce（300ms）与 `waitForImages` 是否给足了时间。

- [ ] **Step 3: 手动验收（设计文档第 12 节，逐项勾选）**

Run:

```bash
/Users/ling/fvm/versions/3.47.4/bin/flutter run -d macos
```

- [ ] 验收 1：输入网址能正常浏览（用 `https://example.com`）。
- [ ] 验收 2：打开一个懒加载图库站（例如任意博客的图集页），自动滚动后列表数量与页面实际图片数一致。
- [ ] 验收 3：1×1 像素与小图被过滤；格式 chip / 最小边滑块 / 来源 chip / 去重开关都即时生效。
- [ ] 验收 4：点图进入大图预览可缩放，「复制直链」后粘贴到浏览器能打开。
- [ ] 验收 5：逐张与多选下载都成功，文件出现在 `~/Downloads`（`ls ~/Downloads | tail`）。
- [ ] 验收 6：对一个带防盗链的图床站点下载成功（若 blob 通道失败会自动走 Dio 降级，两者都成功才算通过）。
- [ ] 验收 7：无限滚动站点（如小红书 / 微博）在 60 秒内停止并提示「已达扫描上限」，App 不卡死、可中断。

- [ ] **Step 4: Android 冒烟**

Run（需连接设备或启动模拟器）：

```bash
/Users/ling/fvm/versions/3.47.4/bin/flutter run -d android
```

- [ ] 输入网址能浏览；自动扫描能出列表；多选下载后图片出现在系统相册的 `ImgCat` 相册里。
- [ ] 拒绝相册权限时，App 弹出引导对话框，「去设置」能跳到系统设置页。

- [ ] **Step 5: iOS 冒烟（需先在 Xcode 里下载 iOS 模拟器运行时）**

Run:

```bash
/Users/ling/fvm/versions/3.47.4/bin/flutter run -d ios
```

- [ ] 与 Android 相同的三条判定。

- [ ] **Step 6: Windows 冒烟（需 Windows 机器）**

在 Windows 机器上 `flutter run -d windows`，重复验收 1–7。若本机无 Windows 机器，标记为未验证并在交付说明中写明。

- [ ] **Step 7: 记录结果并提交**

把上面各项的实测结果（通过/未通过/未验证）追加到本任务末尾。

```bash
git add integration_test/js_capture_test.dart docs/superpowers/plans/2026-09-22-webpage-image-capture.md
git commit -m "test: JS 抓取与 blob 分块通道端到端测试 + 验收结果"
```

---

## 2. 计划自查

按 writing-plans 的自查清单逐项核对。

**1) 规格覆盖**

| 设计文档章节 | 覆盖任务 |
|---|---|
| 第 3 节 技术选型（Flutter + flutter_inappwebview；不依赖请求级拦截） | Task 1（依赖）、Task 9（纯 JS 主通道）、非本期清单明确排除平台拦截 |
| 第 4 节 架构与模块划分、边界约定 | 第 1 节文件结构 + Task 3–17 的落点 |
| 第 5 节 数据模型（含 `sizeKnown`） | Task 3 |
| 第 6 节 抓取通道（三路并行、URL 归一化、尺寸未知不误杀、增量推送） | Task 9（三路 + 归一化 + 增量 flush）、Task 3/6（尺寸未知） |
| 第 6 节 自动扫整页（40 屏 / 60 秒、提示、进度、可中断） | Task 9（JS 循环与上限）、Task 11（进度条 + 中断 + 上限提示） |
| 第 7 节 下载通道（blob 首选 512KB 分块、Dio 降级带 Cookie/Referer） | Task 12、Task 14 |
| 第 7 节 保存目标（相册 / 下载目录，macOS entitlement） | Task 13 |
| 第 7 节 权限声明（Android / iOS / macOS / Windows） | Task 13 Step 8 |
| 第 8 节 界面（900dp 断点、左右分栏 + 拖拽 + 折叠、移动端 FAB + BottomSheet） | Task 17 |
| 第 8 节 图片面板（列数自适应、角标、多选、筛选栏、操作栏、预览） | Task 15、Task 16 |
| 第 8 节 筛选与去重规则（阈值、一级/二级去重、尺寸未知不过滤） | Task 6、Task 7 |
| 第 9 节 错误处理 9 种场景 | 加载失败→Task 11；无限滚动→Task 9/11；403 降级→Task 14；>50MB→Task 12/14 全流式；磁盘不足→Task 14（逐项捕获写失败，不中断其他项）；权限被拒→Task 13/17；页面跳转隔离→Task 11/17；Android 渲染崩溃→Task 11；WebView2 缺失→Task 17 |
| 第 10 节 测试策略（纯单测 / JS fixture 集成 / Widget 三宽度 / 平台冒烟 / 手动清单） | Task 3–8、12–15（纯单测）、Task 18（fixture 集成 + 冒烟 + 手动清单）、Task 15、Task 17（Widget 三宽度） |
| 第 11 节 风险与待验证（Windows spike 优先、无请求级拦截、无限滚动、macOS 沙盒、WebView2） | Task 2（阻塞 spike 与回退判定）、Task 9、Task 11、Task 13、Task 17 |
| 第 12 节 验收标准 1–7 | Task 18 Step 3 逐条勾选 |

「磁盘空间不足」的落地方式说明：不引入磁盘探测依赖，改为逐项捕获写入异常并继续其他项，满足「报错不中断其他项」；预检部分在一期省略，二期若要做自定义下载目录时一并补。

**2) 占位符扫描**

计划中不出现 TBD / TODO / “加适当的错误处理” / “同 Task N” 这类写法；每个改动代码的步骤都给了完整代码，校验命令与预期输出逐条写明。

**3) 跨任务类型与命名一致性**

- `ImageAsset` 字段：`url / mimeType / width / height / byteSize / source`，`sizeKnown` / `minSide` / `merge` / `fromJson` / `toJson`——Task 3 定义，Task 6/7/10/14/15/16 使用，名称一致。
- `ImageSource` 枚举：`img / srcset / cssBackground / dynamic`——Task 3 定义，Task 6/9/15 使用；JS 侧字符串与枚举 `name` 一字不差。
- 桥协议：handler `imgcat`；消息 `batch` / `scan` / `blob`；字段 `pageUrl / assets[] / state / screen / maxScreens / found / id / seq / data / last / mime / error`——Task 8 定义，Task 9（JS 生产）、Task 11（转发）、Task 12/14（消费）一致。
- 常量：`kBridgeHandlerName`、`kBlobChunkBytes`、`kMaxScanScreens`、`kScanTimeout`（Task 8）↔ Task 9/11 使用；`kDefaultMinSide`、`kAllFormats`（Task 6）↔ Task 15 使用；`kTileMaxExtent`（Task 15）；`kPanelBreakpoint` / `kPanelMinWidth` / `kPanelMaxWidth`（Task 17）。
- `JsChannel` / `JsChannelHolder` / `WebViewJsChannel`：Task 11 定义，Task 14、Task 18 使用。
- `SaveTarget` / `createSaveTarget()` / `SaveException` / `DownloadsSaveTarget` / `GallerySaveTarget`：Task 13 定义，Task 14、Task 17 使用。
- 下载模块的接缝：`BlobChunkSink`（Task 14 Step 1）、`DownloadExecutor`（Task 14 Step 3）；`DownloadController({required executor, required blobSink})`（Task 14 Step 4）——Task 17 用 `executor: DownloadService(...)` + `blobSink: WebViewBlobFetcher(...)` 构造，测试用 `FakeDownloadExecutor` + `FakeBlobSink`（Task 14 Step 5）。
- `DownloadController.downloadAll / retry / statusOf / errorOf / locationOf / needsPermission / progressLabel / isBusy / acceptBlobChunk / openPermissionSettings`：Task 14 定义，Task 15、Task 16、Task 17 使用。
- `BrowserPage` 构造参数在 Task 11 与 Task 17 两次出现，字段集合以 Task 17 的调用点为准，Task 11 里逐项对齐（`onBlobChunk`、`onScanLimitReached`、`onPageSwitchNeeded`、`onTapCaptureCount`、`contentOverride`）。

---

## 3. 执行方式

计划已保存到 `docs/superpowers/plans/2026-09-22-webpage-image-capture.md`。两种执行方式：

**1. Subagent-Driven（推荐）** — 每个任务派一个新的 subagent 实现，任务之间由我做两阶段审查，迭代快、上下文干净。

**2. Inline Execution** — 在当前会话里按 `superpowers:executing-plans` 批量执行，带检查点。

选哪种？
