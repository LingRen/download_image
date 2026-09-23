import 'package:flutter/foundation.dart';

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

  /// 是否等于默认筛选（用于决定要不要显示「重置」）。
  bool get isDefault {
    const defaults = FilterSettings();
    return minSide == defaults.minSide &&
        mergeVariants == defaults.mergeVariants &&
        setEquals(enabledFormats, defaults.enabledFormats) &&
        setEquals(enabledSources, defaults.enabledSources);
  }

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
