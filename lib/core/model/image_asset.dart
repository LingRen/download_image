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