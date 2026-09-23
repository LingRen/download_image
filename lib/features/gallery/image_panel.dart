import 'dart:async';

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
    this.onDownloadFailed,
    this.onArchive,
    this.onCollapse,
    this.allowArchive = false,
  });

  final CaptureController capture;
  final DownloadController download;
  final void Function(ImageAsset asset) onOpenPreview;

  /// 下载因相册权限被拒时由外层弹引导。
  final VoidCallback? onPermissionDenied;

  /// 非权限类失败（镜像 403、写盘失败等）时由外层提示。`downloadAll` 从不抛异常，
  /// 不提就等于「点了没反应」。
  final void Function(List<ImageAsset> failed)? onDownloadFailed;

  /// 打包下载（仅桌面端）。由外层执行并提示结果；本面板只负责把目标列表交出去。
  final Future<void> Function(List<ImageAsset> assets)? onArchive;

  /// 宽屏下由外壳传入以在面板头部显示折叠按钮；移动端 BottomSheet 里为 null。
  final VoidCallback? onCollapse;

  /// 桌面端为 true，操作栏显示「打包 ▾」菜单。
  final bool allowArchive;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([capture, download]),
      builder: (context, _) {
        final assets = capture.visibleAssets;
        final selectedUrls = capture.selectedUrls; // selectedUrls 是深拷贝，每帧只取一次
        final selected = [
          for (final asset in assets)
            if (selectedUrls.contains(asset.url)) asset,
        ];
        return Column(
          key: const Key('image-panel'),
          children: [
            if (onCollapse != null) ...[
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  key: const Key('panel-collapse'),
                  tooltip: '折叠图片面板',
                  onPressed: onCollapse,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.view_sidebar),
                ),
              ),
              const Divider(height: 1),
            ],
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
              assets: assets,
              selected: selected,
              onPermissionDenied: onPermissionDenied,
              onDownloadFailed: onDownloadFailed,
              onArchive: onArchive,
              allowArchive: allowArchive,
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
        child: Text(
          text,
          key: const Key('panel-empty'),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.capture,
    required this.download,
    required this.assets,
    required this.selected,
    required this.onPermissionDenied,
    required this.onDownloadFailed,
    required this.onArchive,
    required this.allowArchive,
  });

  final CaptureController capture;
  final DownloadController download;

  /// 面板算好的可见列表，用于「打包全部」。
  final List<ImageAsset> assets;

  /// 面板已算好的选中集（可见顺序），避免在此重复全量计算。
  final List<ImageAsset> selected;
  final VoidCallback? onPermissionDenied;
  final void Function(List<ImageAsset> failed)? onDownloadFailed;
  final Future<void> Function(List<ImageAsset> assets)? onArchive;
  final bool allowArchive;

  @override
  Widget build(BuildContext context) {
    final selectionLabel = download.isBusy
        ? download.progressLabel
        : '已选 ${selected.length} 张';
    final archiveEnabled = !download.isBusy && onArchive != null;

    if (!allowArchive) {
      // 移动端保持单行：全选 / 清空 / 说明 / 下载。
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            _selectAllButton(),
            _selectNoneButton(),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                selectionLabel,
                key: const Key('selection-label'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            _downloadButton(),
          ],
        ),
      );
    }

    // 桌面端两行：第一行选择状态，第二行下载 / 打包入口。
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _selectAllButton(),
              _selectNoneButton(),
              const Spacer(),
              Flexible(
                child: Text(
                  selectionLabel,
                  key: const Key('selection-label'),
                  style: Theme.of(context).textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              PopupMenuButton<_ArchiveAction>(
                key: const Key('archive-menu'),
                tooltip: '打包下载',
                enabled: archiveEnabled,
                padding: EdgeInsets.zero,
                onSelected: (action) {
                  final targets = action == _ArchiveAction.selected
                      ? selected
                      : assets;
                  if (targets.isNotEmpty) unawaited(onArchive?.call(targets));
                },
                itemBuilder: (context) => [
                  PopupMenuItem<_ArchiveAction>(
                    value: _ArchiveAction.selected,
                    enabled: selected.isNotEmpty,
                    child: Text('打包选中 (${selected.length})'),
                  ),
                  PopupMenuItem<_ArchiveAction>(
                    value: _ArchiveAction.all,
                    child: Text('打包全部可见 (${assets.length})'),
                  ),
                ],
                // 纯展示容器：点击手势由 PopupMenuButton 自带的 InkWell 接管，
                // 用 OutlinedButton(onPressed: null) 会长期呈禁用样式。
                child: _ArchiveButton(enabled: archiveEnabled),
              ),
              const SizedBox(width: 8),
              _downloadButton(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _selectAllButton() => TextButton(
    key: const Key('select-all'),
    onPressed: capture.selectAllVisible,
    child: const Text('全选'),
  );

  Widget _selectNoneButton() => TextButton(
    key: const Key('select-none'),
    onPressed: capture.clearSelection,
    child: const Text('清空选择'),
  );

  Widget _downloadButton() => FilledButton.icon(
    key: const Key('download-selected'),
    onPressed: download.isBusy || selected.isEmpty
        ? null
        : () async {
            await download.downloadAll(selected);
            if (download.needsPermission) {
              onPermissionDenied?.call();
              return;
            }
            final failed = <ImageAsset>[
              for (final asset in selected)
                if (download.errorOf(asset.url) != null) asset,
            ];
            if (failed.isNotEmpty) onDownloadFailed?.call(failed);
          },
    icon: const Icon(Icons.download),
    label: const Text('下载'),
  );
}

enum _ArchiveAction { selected, all }

/// 「打包 ▾」的静态外观。手势由外层 PopupMenuButton 的 InkWell 处理，
/// 这里只负责按 [enabled] 呈现可用 / 禁用配色。
class _ArchiveButton extends StatelessWidget {
  const _ArchiveButton({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = enabled ? scheme.onSurface : scheme.onSurface.withValues(
      alpha: 0.38,
    );
    final border = enabled ? scheme.outline : scheme.outlineVariant;

    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_zip_outlined, size: 18, color: foreground),
          const SizedBox(width: 6),
          Text(
            '打包',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: foreground),
          ),
          Icon(Icons.arrow_drop_down, size: 20, color: foreground),
        ],
      ),
    );
  }
}
