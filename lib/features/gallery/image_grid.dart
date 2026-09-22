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
    // 缩略图按显示尺寸解码，避免几百张大图按原分辨率撑爆 ImageCache。
    final cacheSize = (kTileMaxExtent * MediaQuery.devicePixelRatioOf(context)).round();
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
              cacheWidth: cacheSize,
              cacheHeight: cacheSize,
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
            child: IconButton(
              key: Key('tile-preview-${asset.url}'),
              onPressed: onPreview,
              iconSize: 16,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              // 默认 padded 命中区会被撑到 48×48，盖住 tile 中心并抢走点选手势。
              style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              icon: Icon(
                Icons.zoom_in,
                color: Colors.white.withValues(alpha: 0.9),
              ),
            ),
          ),
        ],
      ),
    );
  }
}