import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 浏览器导航状态。
class BrowserController extends ChangeNotifier {
  InAppWebViewController? _webViewController;
  bool _loading = false;
  double _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;
  String? _errorText;

  bool get isLoading => _loading;
  double get progress => _progress;
  bool get canGoBack => _canGoBack;
  bool get canGoForward => _canGoForward;

  /// 主框架加载失败时的错误文案；为空表示正常。
  String? get errorText => _errorText;

  void attachWebView(InAppWebViewController controller) {
    _webViewController = controller;
  }

  void updateLoading({required bool loading, double? progress}) {
    _loading = loading;
    if (progress != null) _progress = progress;
    notifyListeners();
  }

  void updateNavigationState({required bool canGoBack, required bool canGoForward}) {
    if (_canGoBack == canGoBack && _canGoForward == canGoForward) return;
    _canGoBack = canGoBack;
    _canGoForward = canGoForward;
    notifyListeners();
  }

  void setError(String? text) {
    _errorText = text;
    notifyListeners();
  }

  Future<void> load(Uri url) async {
    setError(null);
    await _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url.toString())));
  }

  Future<void> reload() async {
    setError(null);
    await _webViewController?.reload();
  }

  Future<void> goBack() async => _webViewController?.goBack();

  Future<void> goForward() async => _webViewController?.goForward();
}