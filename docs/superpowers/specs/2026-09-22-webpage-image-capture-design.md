# 网页图片抓取下载器 — 设计文档

日期：2026-09-22
状态：已与用户确认，待实施

## 1. 目标

做一个跨端 App：用户在 App 内置浏览器里打开任意网页，App 自动滚动整页触发所有图片加载，实时汇总成图片列表，供用户筛选、预览、批量下载。

**支持平台**：macOS、Windows、Android、iOS（四端一套 UI）。

**核心使用路径**：输入网址 → 打开页面 → 自动扫整页 → 列表持续追加 → 筛选/去重 → 选中 → 下载到相册或下载文件夹。

## 2. 非目标（二期）

- zip 打包下载
- 历史记录（抓过的页面可回看、可重下）
- App 内下载管理器（App 内浏览/删除已下载文件）

一期不做，设计上不预留复杂抽象。

## 3. 技术选型

**Flutter 单代码库 + `flutter_inappwebview`**。

理由：`flutter_inappwebview` 6.1.5 是目前唯一同时支持 Android / iOS / macOS / Windows 的 WebView 组件（macOS 与 Windows 支持均在 6.1.0 加入），一套 UI 和一套抓取逻辑即可覆盖四端。

被否决的方案：

- **Tauri 2**：包体小、Rust 后端强，但移动端 WebView 控制与拦截能力弱，拦截只能靠 JS 注入，遇到问题无退路。
- **原生分端（SwiftUI + Compose + WinUI）**：能力最强、审核最稳，但等于三套 UI + 三套拦截逻辑，维护成本过高。

**关键前提（决定架构的事实）**：

1. **WKWebView（iOS / macOS）不提供 http/https 请求拦截 API。** Apple 工程师在开发者论坛明确回复：没有 API 可以直接拦截 WKWebView 的入站流量，`WKURLSchemeHandler` 只对自定义 scheme 生效，无法用于 `http`/`https`。（参考 Apple Developer Forums thread 660636、766264）
2. **Android WebView 的 `shouldInterceptRequest`、Windows WebView2 的 `WebResourceRequested` 可以做到请求级拦截**，但两端 API 与返回语义不同，无法统一。
3. **防盗链问题**：大量图床校验 `Referer` / `Cookie`，原生 HTTP 客户端直接下载会返回 403。可靠做法是在 WebView 内部用 `fetch` 取 blob 再回传，天然复用页面的登录态与 Referer。这意味着抓取与下载应共用同一条 JS 桥通道。

由第 1、2 条可知：抓取主通道不依赖平台拦截，而是**注入 JS**，这样四端行为完全一致；平台拦截仅作为 Android / Windows 的可选增强。

## 4. 架构

按功能切模块，平台差异集中收敛，其余模块不感知平台。

```text
lib/
  app/                    应用壳、路由、主题、响应式断点
  features/
    browser/              WebView 页：地址栏、加载进度、平台拦截增强
    capture/              抓取：注入脚本、消息解析、过滤与去重
    gallery/              列表：网格、筛选栏、大图预览
    download/             下载：blob 接收器、保存目标（相册/下载夹）
  core/
    bridge/               JS ↔ Dart 协议：消息定义与解析
    model/                ImageAsset 等领域模型
```

**边界约定**：

- `core/bridge` 定义唯一的消息格式：JS 只发这一种，Dart 只解析这一种。抓取与下载共用。
- 平台差异只允许出现在 `download/save_target`（保存位置）与 `browser` 的平台增强（请求级拦截）两处。
- `capture` 与 `gallery` 为纯逻辑 + 纯 UI，无平台依赖，可独立测试。

## 5. 数据模型

```dart
class ImageAsset {
  final String url;         // 已归一化的绝对 URL
  final String? mimeType;
  final int? width, height;
  final int? byteSize;      // 来自 PerformanceEntry
  final ImageSource source; // img / srcset / cssBackground / dynamic
  final bool sizeKnown;     // 尺寸未知时不得参与过滤
}
```

## 6. 抓取通道

注入 JS（文档开始时注入，确保不漏早期请求），三路并行汇入同一个聚合器：

1. `PerformanceObserver` 监听 `resource` 类型 → 拿到所有实际加载过的 URL 与传输体积，覆盖 JS 动态加载的图片。
2. `MutationObserver` 监听 DOM 新增节点与 `style` 属性变化 → 覆盖懒加载与背景图。
3. 全量扫描：`img.currentSrc`（浏览器已从 srcset 选好）、`srcset` 取最大候选、`getComputedStyle().backgroundImage`、`<picture><source>`、`<svg><image>`。

**必须处理的三个细节**：

- URL 用 `new URL(u, location.href).href` 归一化，兼容相对路径。
- 尺寸优先取 `naturalWidth/Height`；取不到的置 `sizeKnown = false`，**不参与尺寸过滤**，避免误杀，UI 上标注"尺寸未知"。
- **增量推送**：每发现一批就 `callHandler` 推一次，不等扫完，用户能立刻看到列表在增长。

### 自动扫整页

分段 `scrollTo` 到底，每段等待新图 `img.complete`，最后滚回原位。

**硬性上限：最多 40 段或 60 秒，先到者生效。** 小红书、微博这类无限滚动页面永远滚不完，必须有上限。达到上限时提示"已达扫描上限，可手动继续滚动后再次扫描"。UI 显示"第 12/40 屏"，并允许用户随时中断。

## 7. 下载通道

两级降级：

1. **首选 — blob 回传**：页面内 `fetch(url, { credentials: 'include' })` → blob → base64 **按 512KB 分块**回传，原生侧边收边 append 写文件。目的是绕开防盗链、复用登录态；分块是为了避免大图 base64 全量驻留内存。
2. **降级 — 原生直下**：Dio 携带从 WebView 导出的 Cookie 与 Referer，速度快、不占 WebView 内存。失败时自动回退到策略 1。

**保存目标**：

- 移动端（Android / iOS）：存系统相册。用 `gal` 包，Android 走 MediaStore（Android 10+ 免存储权限），iOS 需 `NSPhotoLibraryAddUsageDescription`。
- 桌面端（macOS / Windows）：存下载目录。**macOS 沙盒下需要 `file_selector` 让用户授权一次目录并持久化书签**，这是桌面端唯一的绕点。

**权限声明**：Android `INTERNET`；iOS `NSPhotoLibraryAddUsageDescription`；macOS 需 `com.apple.security.network.client` 与 `com.apple.security.files.user-selected.read-write`；Windows 无需额外声明。

## 8. 界面

**一个断点：900dp。**

- **≥900dp（桌面 / 平板横屏）**：左右分栏。左 WebView，右图片面板，可拖拽调宽，面板可折叠。桌面额外提供地址栏（后退/前进/刷新）。
- **<900dp（手机）**：WebView 全屏，右下浮动按钮显示"已捕获 12 张"，点开为全屏 BottomSheet 图片面板。

**图片面板**：网格列数随宽度自适应（手机 3 列、平板 5 列、桌面 6–8 列）。每格为缩略图 + 角标（尺寸/格式）+ 多选圈。

- 顶部筛选栏：最小边滑块、格式 chip（JPG / PNG / GIF / WebP / SVG）、去重开关、来源筛选（`<img>` 标签 / CSS 背景图 / 动态加载）。
- 底部操作栏：全选 / 已选 N 张 / 下载。
- 点击图片进入大图预览（可缩放），底部提供"复制直链"与"下载这张"。

### 筛选与去重规则

- **过滤**（阈值可调）：最小边 < 64px、1×1 像素、`data:` 与 `blob:` 协议。
- **一级去重**：URL 完全相同 → 合并。
- **二级去重**：同路径的尺寸变体（`?w=300` / `?w=900`，或 `_300x300` 后缀）→ 只保留像素最大的一个。默认开启，可关闭。
- 尺寸未知的图片不过滤，单独标注。

## 9. 错误处理与边界

| 场景 | 处理 |
|---|---|
| 页面加载失败 / 超时 | 错误页 + 重试 |
| 无限滚动页面 | 40 屏 / 60 秒上限，提示可手动续扫 |
| 图片 403 / 已失效 | 列表项标红"下载失败"，支持单张重试，自动降级原生直下 |
| 超过 50MB 的大图 | 强制走分块流式保存，显示进度 |
| 磁盘空间不足 | 下载前预检，报错不中断其他项 |
| 相册权限被拒 | 引导跳转系统设置；桌面端退化为存下载文件夹 |
| 页面跳转 / 登录 | 结果按页面 URL 隔离，跳转时提示"已切换页面，是否清空列表" |
| Android WebView 渲染进程崩溃 | 捕获并重建，保留已抓列表 |
| Windows 未安装 WebView2 Runtime | 启动时用 `WebViewEnvironment.getAvailableVersion()` 检测，缺失则给出下载引导页 |

## 10. 测试策略

- **纯单元测试**（覆盖价值最高，无平台依赖）：URL 归一化、srcset 最大候选选取、两级去重、过滤规则、base64 分块重组。
- **JS 抓取逻辑测试**：构造 HTML fixture（含懒加载、背景图、srcset、动态插入），在 `integration_test` 中运行，断言抓到的 URL 集合与预期完全一致。
- **Widget 测试**：三种宽度下的布局适配、多选状态流转。
- **平台冒烟**：macOS / Windows / Android / iOS 各跑一遍核心闭环。
- **手动验收清单**：真实站点逐项验证——懒加载图库、CSS 背景图站点、带防盗链的图床、无限滚动站点。

## 11. 风险与待验证项

| 风险 | 影响 | 应对 |
|---|---|---|
| `flutter_inappwebview` 的 **Windows 支持为 initial 状态** | 可能导致 Windows 端不可用，动摇四端方案 | **实施第一步先做 Windows 端可行性验证（时间盒 spike）**：验证 WebView 能加载页面、JS 注入能执行、`callHandler` 能回传。若失败，Windows 端单独评估替代方案 |
| WKWebView 无请求级拦截能力（Apple 已确认无 API） | iOS / macOS 抓不到"加载失败"与"被 CSP 拦截"的请求 | 已通过 JS 主通道规避；设计上不依赖请求级拦截 |
| 无限滚动 / 有风控的站点 | 自动滚动可能触发风控或永远滚不完 | 40 屏 / 60 秒硬上限；用户可在页面内正常登录后再扫描 |
| macOS 沙盒目录权限 | 无法直接写下载目录 | 首次下载时用 `file_selector` 授权并持久化书签 |
| Windows 10 可能未预装 WebView2 Runtime | 用户启动即失败 | 启动检测 + 引导安装页 |

## 12. 验收标准

一期完成时，下列全部成立：

1. 四端均可在 App 内输入网址并正常浏览网页。
2. 打开含懒加载图片的页面，自动滚动后列表能捕获到图片，且数量与页面实际图片数一致。
3. 列表能正确过滤小图与 1×1 像素，能按尺寸/格式筛选，能对同图多尺寸去重。
4. 能对大图预览、复制直链。
5. 逐张与多选下载均成功；移动端图片出现在系统相册，桌面端文件出现在下载目录。
6. 对带防盗链的图床站点，下载成功（验证 blob 回传通道有效）。
7. 无限滚动站点在 60 秒内自动停止并给出提示，App 不卡死。