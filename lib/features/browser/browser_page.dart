import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 临时探针：只验证「页面能加载 + 注入 JS 能执行 + callHandler 能回传」。
/// Task 11 会把这个文件整体替换为正式实现。
///
/// payload 中额外携带 `title: document.title`，用于机器判定「页面确实加载成功」。
const String _probeScript = '''
(function () {
  function fire() {
    if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) return false;
    window.flutter_inappwebview.callHandler('imgcat', JSON.stringify({
      type: 'batch',
      pageUrl: location.href,
      title: document.title,
      assets: [{ url: location.href + 'probe.png', w: 120, h: 80, size: 1024, mime: 'image/png', source: 'img' }]
    }));
    return true;
  }
  var timer = setInterval(function () { if (fire()) clearInterval(timer); }, 200);
  setTimeout(function () { clearInterval(timer); }, 10000);
})();
''';

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key, required this.initialUrl});

  final Uri initialUrl;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  String _received = '（尚未收到协议消息）';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            '收到协议消息: $_received',
            key: const Key('probe-output'),
          ),
        ),
        Expanded(
          child: InAppWebView(
            initialUrlRequest:
                URLRequest(url: WebUri(widget.initialUrl.toString())),
            initialUserScripts: UnmodifiableListView<UserScript>([
              UserScript(
                source: _probeScript,
                injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                forMainFrameOnly: false,
              ),
            ]),
            onWebViewCreated: (controller) {
              controller.addJavaScriptHandler(
                handlerName: 'imgcat',
                callback: (args) {
                  final raw = args.isNotEmpty ? args.first : null;
                  // 偏差 B：把原始消息打印到 stdout，便于机器判定 spike 结果。
                  debugPrint('SPIKE_HANDLER_RECEIVED: ${raw?.toString() ?? 'null'}');
                  setState(() => _received = raw?.toString() ?? 'null');
                  return null;
                },
              );
            },
          ),
        ),
      ],
    );
  }
}