import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Windows 上未安装 WebView2 Runtime 时返回 true（其他平台恒为 false）。
Future<bool> isWebView2Missing() async {
  if (!Platform.isWindows) return false;
  try {
    final version = await WebViewEnvironment.getAvailableVersion();
    return version == null || version.isEmpty;
  } catch (_) {
    return true;
  }
}
