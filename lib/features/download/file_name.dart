/// mime → 扩展名，只覆盖一期支持的格式。
const Map<String, String> _mimeExtensions = {
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/png': 'png',
  'image/gif': 'gif',
  'image/webp': 'webp',
  'image/svg+xml': 'svg',
};

/// 从 URL 推导保存用的文件名：不信任 URL，路径段与危险字符都会被清洗。
/// 百分号转义由 `Uri.pathSegments` 负责，这里不再解码，避免二次解码崩溃。
String buildFileName(String url, {String? mimeType}) {
  final uri = Uri.tryParse(url);
  var name = '';
  if (uri != null && uri.pathSegments.isNotEmpty) {
    name = uri.pathSegments.last;
  }
  name = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  name = name.replaceAll(RegExp(r'^\.+'), '');
  if (name.isEmpty) name = 'image';
  if (!name.contains('.')) {
    final ext = _mimeExtensions[mimeType?.toLowerCase()];
    if (ext != null) name = '$name.$ext';
  }
  return name;
}

/// 下载目录里已存在同名文件时使用的备选名：`i.jpg` → `i (1).jpg`。
String uniqueFileName(String fileName, int index) {
  if (index <= 0) return fileName;
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0) return '$fileName ($index)';
  return '${fileName.substring(0, dot)} ($index)${fileName.substring(dot)}';
}

/// 桌面端打包下载的压缩包名：`imgcat-20260923-153045.zip`。
String buildArchiveName(DateTime now) {
  String two(int value) => value.toString().padLeft(2, '0');
  final stamp =
      '${now.year}${two(now.month)}${two(now.day)}'
      '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
  return 'imgcat-$stamp.zip';
}
