import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/bridge/js_channel.dart';

class WebViewJsChannel implements JsChannel {
  WebViewJsChannel(this.controller);

  final InAppWebViewController controller;

  @override
  Future<void> call(String function, Map<String, Object?> args) async {
    final payload = jsonEncode(args);
    final source = 'window.__imgcat && window.__imgcat.$function($payload);';
    await controller.evaluateJavascript(source: source);
  }
}