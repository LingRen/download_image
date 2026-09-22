import '../../core/model/image_asset.dart';

const Set<String> _dimensionParams = {'w', 'h', 'width', 'height', 'size'};

final RegExp _dimensionSuffix = RegExp(r'[_-]\d+x\d+(?=\.|$)');

/// 尺寸变体归组用的 key：去掉尺寸类查询参数与 `_300x300` / `-300x300` 路径后缀。
/// 保留其它查询参数，避免把不同资源误判为同一张图。
String variantKey(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return url;
  final path = uri.path.replaceAll(_dimensionSuffix, '');
  final query = uri.queryParameters.entries
      .where((entry) => !_dimensionParams.contains(entry.key.toLowerCase()))
      .map((entry) => '${entry.key}=${entry.value}')
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