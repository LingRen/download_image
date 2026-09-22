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