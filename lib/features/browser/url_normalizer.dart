/// 把用户在地址栏输入的内容归一化成合法的 http(s) 绝对 URL。
/// 只在地址栏入口使用；页面内抓到的 URL 由 JS 侧 `new URL(u, location.href)` 处理。
String normalizeInputUrl(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('请输入网址');
  }
  final candidate = trimmed.contains('://') ? trimmed : 'https://$trimmed';
  final uri = Uri.parse(candidate);
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw FormatException('只支持 http / https，收到：${uri.scheme}');
  }
  if (uri.host.isEmpty) {
    throw const FormatException('网址缺少主机名');
  }
  return uri.toString();
}
