import 'package:flutter/material.dart';

import 'app/app.dart';
import 'features/browser/platform/webview2_check.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (await isWebView2Missing()) {
    runApp(const _WebView2MissingApp());
    return;
  }
  runApp(const ImageCaptureApp());
}

/// Windows 10 可能未预装 WebView2 Runtime（设计文档第 9 节）。
class _WebView2MissingApp extends StatelessWidget {
  const _WebView2MissingApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.download_for_offline_outlined, size: 56),
                SizedBox(height: 16),
                Text(
                  '缺少 WebView2 Runtime',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  '本应用依赖 Microsoft Edge WebView2 Runtime。请到 '
                  'https://developer.microsoft.com/microsoft-edge/webview2/ 下载安装后重新打开应用。',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
