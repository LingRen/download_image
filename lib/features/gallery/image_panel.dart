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
        final selected = [
          for (final asset in assets)
            if (capture.selectedUrls.contains(asset.url)) asset,
        ];
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
            _ActionBar(
              capture: capture,
              download: download,
              selected: selected,
              onPermissionDenied: onPermissionDenied,
            ),
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
  const _ActionBar({
    required this.capture,
    required this.download,
    required this.selected,
    this.onPermissionDenied,
  });

  final CaptureController capture;
  final DownloadController download;

  /// 面板已算好的选中集（可见顺序），避免在此重复全量计算。
  final List<ImageAsset> selected;
  final VoidCallback? onPermissionDenied;

  @override
  Widget build(BuildContext context) {
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