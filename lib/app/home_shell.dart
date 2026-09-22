import 'dart:async';

import 'package:flutter/material.dart';

import '../core/bridge/js_channel.dart';
import '../core/model/image_asset.dart';
import '../features/browser/browser_controller.dart';
import '../features/browser/browser_page.dart';
import '../features/capture/capture_controller.dart';
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
        onDownload: _downloadFromPreview,
      ),
    ));
  }

  /// 预览页「下载这张」：`downloadAll` 从不抛异常，失败信息只在 `_errors` 里，
  /// 所以要在这里读回来给用户提示，否则非权限类失败表现为「点了没反应」。
  Future<void> _downloadFromPreview(ImageAsset asset) async {
    // 预览页的「下载这张」不受 isBusy 约束：连点第二次会被 downloadAll 的 _busy
    // 早退，此时继续读 needsPermission 会拿到上一批的结果、重复弹权限引导。
    if (_download.isBusy) return;
    await _download.downloadAll(<ImageAsset>[asset]);
    if (!mounted) return;
    if (_download.needsPermission) {
      await _showPermissionGuide();
      return;
    }
    final error = _download.errorOf(asset.url);
    if (error != null) _showSnack('下载失败：$error');
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
    // body 恒为 Row、首个子节点恒为 Expanded(browser)：跨过 900dp 断点时兄弟序列的
    // 形状不变，BrowserPage 的 Element 不会被丢弃重建（否则 _currentUrl 丢失、WebView
    // 会退回 initialUrl）。图片面板只是条件追加在后面。
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            Expanded(child: _buildBrowser()),
            if (isWide && !_panelCollapsed) ...[
              _DragHandle(
                onDrag: (delta) => setState(() {
                  _panelWidth = (_panelWidth - delta).clamp(kPanelMinWidth, kPanelMaxWidth);
                }),
              ),
              SizedBox(
                key: const Key('panel-docked'),
                width: _panelWidth,
                child: _buildPanel(showCollapse: true),
              ),
            ],
          ],
        ),
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
              listenable: Listenable.merge([_capture, _download]),
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

  Widget _buildPanel({bool showCollapse = false}) => ImagePanel(
        capture: _capture,
        download: _download,
        onOpenPreview: _openPreview,
        onPermissionDenied: _showPermissionGuide,
        onDownloadFailed: (failed) =>
            _showSnack('${failed.length} 张下载失败：${_download.errorOf(failed.first.url)}'),
        // 折叠按钮放在面板自己的头部：叠在浏览器右上角会与地址栏的「重新扫描整页」
        // 命中区重叠约 44×44dp，宽屏下那个按钮几乎点不到。移动端 BottomSheet 里为 null。
        onCollapse: showCollapse ? () => setState(() => _panelCollapsed = true) : null,
      );

  Widget _buildBrowser() => BrowserPage(
        initialUrl: widget.initialUrl ?? _fallbackUrl,
        browser: _browser,
        capture: _capture,
        jsChannel: _jsChannel,
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