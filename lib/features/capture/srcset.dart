/// srcset 中的一个候选。
class SrcsetCandidate {
  const SrcsetCandidate(this.url, this.width);

  final String url;

  /// 来自 `300w` 描述符的像素宽，或来自 `2x` 描述符折算（1x = 1000）；
  /// 没有描述符时为 null。
  final int? width;
}

/// 解析 srcset 字符串，非法片段被跳过。
List<SrcsetCandidate> parseSrcset(String? srcset) {
  final results = <SrcsetCandidate>[];
  if (srcset == null || srcset.trim().isEmpty) return results;
  for (final raw in srcset.split(',')) {
    final part = raw.trim();
    if (part.isEmpty) continue;
    final fields = part.split(RegExp(r'\s+'));
    final url = fields.first;
    if (url.isEmpty) continue;
    results.add(
      SrcsetCandidate(
        url,
        _parseDescriptor(fields.length > 1 ? fields[1] : null),
      ),
    );
  }
  return results;
}

int? _parseDescriptor(String? descriptor) {
  if (descriptor == null || descriptor.isEmpty) return null;
  final lower = descriptor.toLowerCase();
  final body = lower.substring(0, lower.length - 1);
  if (lower.endsWith('w')) return int.tryParse(body);
  if (lower.endsWith('x')) {
    final scale = double.tryParse(body);
    return scale == null ? null : (scale * 1000).round();
  }
  return null;
}

/// 取像素最大的候选；宽度相同时取先出现的；全部没有描述符时取第一个。
SrcsetCandidate? pickLargest(String? srcset) {
  final candidates = parseSrcset(srcset);
  if (candidates.isEmpty) return null;
  var best = candidates.first;
  for (final candidate in candidates.skip(1)) {
    final bestWidth = best.width ?? -1;
    final width = candidate.width ?? -1;
    if (width > bestWidth) best = candidate;
  }
  return best;
}
