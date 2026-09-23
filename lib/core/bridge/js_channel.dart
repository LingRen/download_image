/// 调用页面内 `window.__imgcat.<function>(<args>)` 的统一入口。
/// 抽象出来是为了让 download 模块不 import flutter_inappwebview，从而可单测。
abstract class JsChannel {
  Future<void> call(String function, Map<String, Object?> args);
}

/// WebView 就绪前为空壳，BrowserPage 创建好 WebView 后 attach。
class JsChannelHolder implements JsChannel {
  JsChannel? _inner;

  void attach(JsChannel channel) => _inner = channel;

  void detach() => _inner = null;

  bool get isReady => _inner != null;

  @override
  Future<void> call(String function, Map<String, Object?> args) async {
    final inner = _inner;
    if (inner == null) {
      throw StateError('WebView 尚未就绪，无法调用 $function');
    }
    await inner.call(function, args);
  }
}
