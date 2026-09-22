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
    this.onPageSwitchNeeded,
    this.onBlobChunk,
    this.onScanLimitReached,
    this.contentOverride,
  });

  final Uri initialUrl;
  final BrowserController browser;
  final CaptureController capture;
  final JsChannelHolder jsChannel;

  /// 检测到主框架跳到了新页面且列表非空时调用，返回用户选择（第一个参数是
  /// 切换前的主框架 URL，第二个是新页 URL）。
  final Future<PageSwitchDecision> Function(String previousUrl, String newUrl)?
      onPageSwitchNeeded;

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

  /// 主框架开始导航前那一批资产的 URL 快照。对话框弹出时新页的图可能已经进来了，
  /// 「清空」只该清掉这些。
  Set<String> _urlsBeforeNavigation = const {};

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
    final previousUrl = _lastMainFrameUrl;
    final isNewPage = previousUrl != null && previousUrl != url;
    _lastMainFrameUrl = url;
    if (isNewPage) {
      // 必须复位，否则新页不会自动扫描、且扫描状态条会停在上一页。
      // keepAssetsForNewPage 是复位扫描态的唯一出口（clear 会连列表一起清掉）。
      _autoScannedForCurrentUrl = false;
      var keepAssets = true;
      if (capture.rawCount > 0) {
        keepAssets =
            await widget.onPageSwitchNeeded?.call(previousUrl, url) != PageSwitchDecision.clear;
      }
      if (keepAssets) {
        capture.keepAssetsForNewPage(url);
      } else {
        // 只删上一个页面的资产，别把新页已经推过来的图也清掉（见 Task 11 ⚠️ 段）。
        if (_urlsBeforeNavigation.isEmpty) {
          capture.clear();
        } else {
          capture.removeUrls(_urlsBeforeNavigation);
        }
        _urlsBeforeNavigation = const {};
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
          listenable: widget.browser,
          builder: (context, _) => widget.browser.isLoading
              ? LinearProgressIndicator(
                  key: const Key('page-loading'),
                  value: widget.browser.progress.clamp(0.0, 1.0),
                  minHeight: 2,
                )
              : const SizedBox.shrink(),
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
      },
      onLoadStart: (controller, url) {
        // 只在确实是「换页」时快照，刷新同一页不重置（否则对话框来不及弹就先被清）。
        final target = url?.toString();
        if (target != null && target != _lastMainFrameUrl) {
          _urlsBeforeNavigation = widget.capture.rawAssets.map((a) => a.url).toSet();
        }
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