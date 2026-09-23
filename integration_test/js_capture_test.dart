import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:download_image/core/bridge/bridge_protocol.dart';
import 'package:download_image/core/bridge/js_channel.dart';
import 'package:download_image/core/model/image_asset.dart';
import 'package:download_image/features/browser/webview_js_channel.dart';
import 'package:download_image/features/capture/capture_controller.dart';
import 'package:download_image/features/capture/capture_script.dart';
import 'package:download_image/features/capture/image_filter.dart';
import 'package:download_image/features/download/blob_file_writer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 端到端 fixture：真实 HTTP 页面 + 真实可解码图片。
///
/// 页面里的图片全部走相对路径，因此只要 `initialUrlRequest` 指向本机服务器，
/// URL 就能正确解析、图片就能真的加载，`naturalWidth/naturalHeight` 才会等于
/// 期望值（假域名会让所有图 404，尺寸变成 null，尺寸过滤断言必然失败）。
///
/// 三路采集的**排他**证据只有一路：挂进 DOM 的图最终一定会被「DOM 全扫」覆盖，
/// 所以只有「只发请求、不挂 DOM」的 `/img/probe-g.jpg` 能单独证明
/// PerformanceObserver 在工作（见测试里的 `fetch` 段）。MutationObserver 无法与
/// DOM 全扫相互排他——任何 mutation 都只是触发一次重扫，最终仍由 DOM 采集，
/// 因此这里不硬造排他断言，只通过「插入新图后多推一批」间接覆盖。
const String _fixtureHtml = '''
<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  .bg1 { width: 200px; height: 200px; background-image: url('/img/bg-1.png'); }
  .bg2 { width: 200px; height: 200px; background-image: url('/img/bg-2.jpg'); }
</style></head><body>
  <img id="a" src="/img/a.jpg" width="300" height="200">
  <img id="b" src="/img/b.png" width="120" height="120">
  <img id="c" src="/img/c.gif" width="1" height="1">
  <picture><source srcset="/img/d-small.webp 300w, /img/d-large.webp 1200w"></picture>
  <div class="bg1"></div>
  <div class="bg2"></div>
  <div id="lazy"></div>
  <div id="spacer" style="height: 4000px"></div>
  <div id="late"></div>
  <script>
    // 占位高度按视口算，而不是写死 4000px：iOS 上没有 viewport meta 时布局视口
    // 高达约 2130 CSS px，2 屏就能越过写死的高度、被误判成「已到底」，
    // 于是「上限用例」在 iOS 上会走 done 而不是 limit。6 倍视口高保证了
    // 「2 屏到不了底、40 屏必定到底」这个不变量在任何视口尺寸下都成立。
    document.getElementById('spacer').style.height =
      Math.max(window.innerHeight * 6, 4000) + 'px';
    // 动态插入一张（懒加载形态之一）：全量扫描与 MutationObserver 都要能覆盖到。
    // 另一张懒加载图由测试在扫描结束后插入，用来观测「发现新图 → 增量再推一批」。
    setTimeout(function () {
      var img = document.createElement('img');
      img.src = '/img/lazy-e.jpg';
      img.width = 240; img.height = 240;
      document.getElementById('lazy').appendChild(img);
    }, 200);
  </script>
</body></html>
''';

/// 页面与测试共用的图片路径 → 内在尺寸。这是「有哪些图」的唯一真源：服务端按它
/// 出图，[_Harness.expectedUrls] 也由它的键派生（`scroll-f`/`probe-g` 由测试注入）。
const Map<String, List<int>> _imageSpec = {
  '/img/a.jpg': [300, 200],
  '/img/b.png': [120, 120],
  '/img/c.gif': [1, 1],
  '/img/d-small.webp': [300, 300],
  '/img/d-large.webp': [1200, 1200],
  '/img/bg-1.png': [200, 200],
  '/img/bg-2.jpg': [200, 200],
  '/img/lazy-e.jpg': [240, 240],
  '/img/scroll-f.jpg': [260, 260],
  '/img/probe-g.jpg': [180, 180],
};

/// 页面引用了、但不会成为独立资产的路径。srcset 只保留最大候选，因此
/// `d-small` 必然落选（`picture` 内的 `source` 只按属性聚合，不保证发起请求）。
/// `d-large` 会被聚合成 `srcset` 资产，只是它的尺寸来自 `1200w` 而非解码。
const Set<String> _excludedPaths = {'/img/d-small.webp'};

/// 极简 SVG：WebKit 会从 width/height 属性得出内在尺寸，所以 `naturalWidth`
/// 精确等于期望值。比手写 PNG 省事，且同样能真实解码。
String _svgImage(int width, int height) =>
    '<svg xmlns="http://www.w3.org/2000/svg" width="$width" height="$height" '
    'viewBox="0 0 $width $height"></svg>';

/// 在真实时间下轮询等待（集成测试用的是 LiveTestWidgetsFlutterBinding）。
Future<void> _waitFor(
  WidgetTester tester,
  bool Function() done,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待超时（${timeout.inSeconds}s）');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 1));
  }
}

/// 等 [counter] 在一个 [quiet] 窗口内不再增长：确认增量批已经推完，
/// 而不是用一个固定延时去赌（固定延时在慢机上会变成同步退化）。
Future<void> _waitQuiet(
  WidgetTester tester,
  int Function() counter,
  Duration quiet,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  var last = counter();
  var since = DateTime.now();
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 1));
    final now = counter();
    if (now != last) {
      last = now;
      since = DateTime.now();
    } else if (DateTime.now().difference(since) >= quiet) {
      return;
    }
  }
  fail(
    '增量通道在 ${quiet.inMilliseconds}ms 静默窗口内始终没有稳定下来'
    '（当前计数 ${counter()}，已等待 ${DateTime.now().difference(since).inMilliseconds}ms）',
  );
}

/// fixture 服务器 + WebView + 桥 + 各通道收集器。
class _Harness {
  _Harness({
    required this.origin,
    required this.webViewController,
    required this.capture,
    required this.jsChannel,
    required this.batches,
    required this.progresses,
    required this.blobChunks,
    required this.scanTerminal,
  });

  final String origin;
  final Future<InAppWebViewController> webViewController;
  final CaptureController capture;
  final JsChannelHolder jsChannel;
  final List<CaptureBatch> batches;
  final List<ScanProgress> progresses;
  final List<BlobChunk> blobChunks;
  final Completer<void> scanTerminal;

  String get fixtureUrl => '$origin/index.html';

  /// 页面里最终会被聚合成资产的全部 URL。
  Set<String> get expectedUrls => {
    for (final path in _imageSpec.keys)
      if (!_excludedPaths.contains(path)) '$origin$path',
  };

  bool hasAsset(String suffix) =>
      capture.rawAssets.any((asset) => asset.url.endsWith(suffix));
}

/// 起服务器、装 WebView/桥，并在加载完成后触发一次 `maxScreens` 屏的扫描。
Future<_Harness> _pumpFixture(
  WidgetTester tester, {
  required int maxScreens,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final origin = 'http://127.0.0.1:${server.port}';
  final fixtureUrl = '$origin/index.html';

  server.listen((request) async {
    // 客户端提前断开或服务器 close 时，写响应会抛异步异常；fixture 里直接忽略。
    try {
      final response = request.response;
      final path = request.uri.path;
      if (path == '/' || path == '/index.html') {
        final bytes = utf8.encode(_fixtureHtml);
        response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..headers.contentLength = bytes.length
          ..add(bytes);
      } else if (_imageSpec.containsKey(path)) {
        final spec = _imageSpec[path]!;
        final bytes = utf8.encode(_svgImage(spec[0], spec[1]));
        response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.parse('image/svg+xml')
          ..headers.contentLength = bytes.length
          ..add(bytes);
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    } catch (_) {
      // 忽略：请求已被取消 / 服务器已关闭。
    }
  });

  final capture = CaptureController();
  final jsChannel = JsChannelHolder();
  final batches = <CaptureBatch>[];
  final progresses = <ScanProgress>[];
  final blobChunks = <BlobChunk>[];
  final scanTerminal = Completer<void>();
  final controllerCompleter = Completer<InAppWebViewController>();

  addTearDown(() async {
    jsChannel.detach();
    await server.close(force: true);
  });

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: InAppWebView(
          // 只给 initialUrlRequest：macOS 侧优先级是 initialFile > initialData >
          // initialUrlRequest，两者都传时 initialData 会赢，页面就不再是本机服务器页面。
          initialUrlRequest: URLRequest(url: WebUri(fixtureUrl)),
          initialUserScripts: UnmodifiableListView<UserScript>([
            UserScript(
              source: kCaptureScript,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              forMainFrameOnly: false,
            ),
          ]),
          onWebViewCreated: (created) {
            if (!controllerCompleter.isCompleted) {
              controllerCompleter.complete(created);
            }
            jsChannel.attach(WebViewJsChannel(created));
            created.addJavaScriptHandler(
              handlerName: kBridgeHandlerName,
              callback: (args) {
                final message = BridgeMessage.parse(
                  args.isNotEmpty ? args.first : null,
                );
                switch (message) {
                  case BlobChunk chunk:
                    blobChunks.add(chunk);
                  case ScanProgress progress:
                    progresses.add(progress);
                    capture.accept(progress);
                    if (!progress.isRunning && !scanTerminal.isCompleted) {
                      scanTerminal.complete();
                    }
                  case CaptureBatch batch:
                    batches.add(batch);
                    capture.accept(batch);
                  case null:
                    break;
                }
                return null;
              },
            );
          },
          onLoadStop: (created, url) async {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            await created.evaluateJavascript(
              source:
                  'window.__imgcat.scan({"maxScreens": $maxScreens, "timeoutMs": 60000});',
            );
          },
        ),
      ),
    ),
  );

  return _Harness(
    origin: origin,
    webViewController: controllerCompleter.future,
    capture: capture,
    jsChannel: jsChannel,
    batches: batches,
    progresses: progresses,
    blobChunks: blobChunks,
    scanTerminal: scanTerminal,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('抓取脚本增量推送、三路采集与 blob 分块通道端到端打通', (tester) async {
    final harness = await _pumpFixture(tester, maxScreens: 40);
    final capture = harness.capture;

    await _waitFor(
      tester,
      () => harness.scanTerminal.isCompleted,
      const Duration(seconds: 60),
    );
    await _waitQuiet(
      tester,
      () => harness.batches.length,
      const Duration(milliseconds: 400),
    );
    final controller = await harness.webViewController;

    // ---------- 增量推送：扫描后页面又出现新图，必须再推一批（只含新图） ----------
    await controller.evaluateJavascript(
      source: '''
      (function () {
        var img = document.createElement('img');
        img.src = '/img/scroll-f.jpg';
        img.width = 260; img.height = 260;
        document.getElementById('late').appendChild(img);
      })();
    ''',
    );
    await _waitFor(
      tester,
      () => harness.hasAsset('scroll-f.jpg'),
      const Duration(seconds: 15),
    );
    await _waitQuiet(
      tester,
      () => harness.batches.length,
      const Duration(milliseconds: 400),
    );
    expect(harness.batches.last.assets.map((asset) => asset.url).toList(), [
      '${harness.origin}/img/scroll-f.jpg',
    ], reason: '增量批只包含新发现的图，不能重推全量快照');
    expect(
      harness.batches.every((batch) => batch.pageUrl == harness.fixtureUrl),
      isTrue,
      reason: '每批增量都带当前页 URL',
    );

    // ---------- PerformanceObserver 独有：只发请求、不进 DOM ----------
    // 这张图不会被 `document.images` / CSS 全扫看到，只能由 resource timing 采集到，
    // 因此它出现（且 source == dynamic）是 PO 那一路真的在工作、而不是被 DOM 全扫兜住的证据。
    await controller.evaluateJavascript(
      source: '''
      fetch('/img/probe-g.jpg').then(function (r) { return r.arrayBuffer(); });
    ''',
    );
    await _waitFor(
      tester,
      () => harness.hasAsset('probe-g.jpg'),
      const Duration(seconds: 15),
    );
    await _waitQuiet(
      tester,
      () => harness.batches.length,
      const Duration(milliseconds: 400),
    );

    // ---------- 扫描进度序列 ----------
    expect(harness.progresses, isNotEmpty);
    expect(harness.progresses.first.state, ScanState.start);
    expect(
      harness.progresses.last.state,
      ScanState.done,
      reason: '占位高 6 倍视口，40 屏足够到底，必须走 done 而不是 limit',
    );
    expect(harness.progresses.last.isRunning, isFalse);
    expect(
      harness.progresses.every((p) => p.pageUrl == harness.fixtureUrl),
      isTrue,
      reason: 'ScanProgress.pageUrl 必须是 fixture 的真实 URL',
    );

    // ---------- Dart 侧 URL 集合 ----------
    final dartUrls = capture.rawAssets.map((asset) => asset.url).toSet();
    expect(
      dartUrls,
      harness.expectedUrls,
      reason: 'Dart 侧拿到的 URL 集合必须与 fixture 完全一致',
    );
    expect(capture.pageUrl, harness.fixtureUrl);

    // ---------- 桥不丢消息：与 JS 侧聚合结果完全相等 ----------
    final jsAssetsRaw = await controller.evaluateJavascript(
      source: 'JSON.stringify(window.__imgcat.assets())',
    );
    final jsUrls = (jsonDecode(jsAssetsRaw as String) as List)
        .cast<String>()
        .toSet();
    expect(jsUrls, harness.expectedUrls, reason: 'JS 侧聚合集合必须与预期一致');
    expect(jsUrls, dartUrls, reason: '桥不能丢消息');

    // ---------- 来源与尺寸语义（真实加载后的内在尺寸） ----------
    final byUrl = {for (final asset in capture.rawAssets) asset.url: asset};

    final aJpg = byUrl['${harness.origin}/img/a.jpg']!;
    expect(aJpg.width, 300);
    expect(aJpg.height, 200);
    expect(aJpg.sizeKnown, isTrue);

    final probeG = byUrl['${harness.origin}/img/probe-g.jpg']!;
    expect(
      probeG.source,
      ImageSource.dynamic,
      reason: '不挂 DOM 的图只能由 PerformanceObserver 采集，来源必须是 dynamic',
    );

    final dLarge = byUrl['${harness.origin}/img/d-large.webp']!;
    expect(dLarge.source, ImageSource.srcset);
    expect(dLarge.width, 1200);
    expect(dLarge.height, isNull);
    expect(dLarge.sizeKnown, isFalse, reason: 'srcset 只给宽度，尺寸未知');

    expect(
      byUrl['${harness.origin}/img/bg-1.png']!.source,
      ImageSource.cssBackground,
    );
    expect(
      byUrl['${harness.origin}/img/bg-2.jpg']!.source,
      ImageSource.cssBackground,
    );
    expect(byUrl['${harness.origin}/img/lazy-e.jpg']!.width, 240);
    expect(byUrl['${harness.origin}/img/lazy-e.jpg']!.height, 240);

    // ---------- 筛选：1×1 真的被尺寸滤镜挡掉 ----------
    final cGif = byUrl['${harness.origin}/img/c.gif']!;
    expect(cGif.sizeKnown, isTrue, reason: '1×1 gif 必须真的解码出尺寸');
    expect(cGif.width, 1);
    expect(cGif.height, 1);
    expect(
      isFilteredOut(cGif, capture.filter),
      isTrue,
      reason: '1×1 必须被尺寸滤镜过滤',
    );
    expect(
      capture.rawCount,
      harness.expectedUrls.length,
      reason: 'rawAssets 不做筛选',
    );

    final visible = capture.visibleAssets;
    expect(
      visible.any((asset) => asset.url == cGif.url),
      isFalse,
      reason: '1×1 像素必须被过滤',
    );
    expect(visible.any((asset) => asset.url == aJpg.url), isTrue);
    expect(
      visible.where((asset) => asset.url == dLarge.url).length,
      1,
      reason: '尺寸未知的图不参与尺寸过滤，因此它会留在可见列表里',
    );

    // ---------- 扫描态复位（Task 17 遗留）----------
    // 先证明 limit 进度会置位 scanReachedLimit：否则下面断言它为 false 是恒真的。
    capture.accept(
      ScanProgress(
        state: ScanState.limit,
        pageUrl: harness.fixtureUrl,
        screen: 40,
        maxScreens: 40,
      ),
    );
    expect(
      capture.scanReachedLimit,
      isTrue,
      reason: 'limit 进度必须置位 scanReachedLimit',
    );

    // 再造出「扫描进行中」的前置状态：否则此刻 _scan 早已是 done，
    // 即便 keepAssetsForNewPage 整段删掉，isScanning 也照样是 false，断言恒真。
    capture.accept(
      ScanProgress(
        state: ScanState.progress,
        pageUrl: harness.fixtureUrl,
        screen: 1,
      ),
    );
    expect(capture.isScanning, isTrue, reason: '前置状态必须先成立，否则后面的复位断言没有证据力');

    capture.keepAssetsForNewPage('${harness.origin}/other.html');
    expect(capture.scan, isNull, reason: '保留分支必须把 _scan 归零');
    expect(capture.isScanning, isFalse);
    expect(capture.scanReachedLimit, isFalse);
    expect(capture.rawCount, harness.expectedUrls.length, reason: '保留分支不能丢图');

    // 清空分支：BrowserPage 的真实走法是 removeUrls(旧页 URL) 紧跟
    // keepAssetsForNewPage(新页 URL)（见 lib/features/browser/browser_page.dart），
    // _scan 的复位由后者完成——removeUrls 本身只删 URL，不碰 _scan。
    capture.accept(
      ScanProgress(
        state: ScanState.progress,
        pageUrl: harness.fixtureUrl,
        screen: 2,
      ),
    );
    expect(capture.isScanning, isTrue);

    capture.removeUrls(dartUrls);
    expect(capture.rawCount, 0, reason: '清空分支必须把旧页 URL 删干净');
    expect(capture.scan, isNotNull, reason: 'removeUrls 只负责删 URL，不负责复位扫描态');

    capture.keepAssetsForNewPage('${harness.origin}/other.html');
    expect(capture.scan, isNull, reason: '清空后不能把 _scan 留在 running');
    expect(capture.isScanning, isFalse);
    expect(capture.rawCount, 0);

    // ---------- blob 分块通道端到端 ----------
    final tempDir = Directory.systemTemp.createTempSync('imgcat_it');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final destination = File('${tempDir.path}/blob.bin');
    final writer = BlobFileWriter(destination);
    await writer.open();

    const totalBytes = 1200000;
    await controller.evaluateJavascript(
      source:
          '''
      (function () {
        var bytes = new Uint8Array($totalBytes);
        for (var i = 0; i < bytes.length; i++) { bytes[i] = i % 251; }
        window.__imgcatTestBlobUrl =
          URL.createObjectURL(new Blob([bytes], { type: 'image/png' }));
        window.__imgcat.fetchAsBase64({
          url: window.__imgcatTestBlobUrl, id: 'it-1', chunkSize: $kBlobChunkBytes
        });
      })();
    ''',
    );

    List<BlobChunk> mine() =>
        harness.blobChunks.where((chunk) => chunk.id == 'it-1').toList();
    await _waitFor(
      tester,
      () => mine().isNotEmpty && mine().last.last,
      const Duration(seconds: 45),
    );

    final chunks = mine();
    // 分块协议：mime 是图片类型、seq 从 0 连续递增、只有最后一块 last == true。
    expect(chunks.length, (totalBytes / kBlobChunkBytes).ceil());
    expect(
      chunks.map((chunk) => chunk.seq).toList(),
      List<int>.generate(chunks.length, (index) => index),
    );
    expect(chunks.where((chunk) => chunk.last).length, 1);
    expect(chunks.last.last, isTrue);
    expect(chunks.every((chunk) => chunk.error == null), isTrue);
    expect(chunks.every((chunk) => chunk.mime == 'image/png'), isTrue);

    for (final chunk in chunks) {
      await writer.add(chunk);
    }
    await writer.close();

    expect(writer.isComplete, isTrue);
    expect(writer.receivedBytes, totalBytes);
    expect(await destination.length(), totalBytes);
    final bytes = await destination.readAsBytes();
    // 首尾 + 每个分块边界各取两点：只测 chunk0/chunk2 的话，中段等长分块的
    // 步进 / 偏移写错（bytesToBase64 或 subarray 用错）照样能全绿。
    // 注意 251 不整除分块大小，所以边界处的期望值是该下标自身的模值而不是 0。
    expect(bytes[0], 0);
    expect(bytes[250], 250);
    expect(bytes[251], 0);
    expect(bytes[kBlobChunkBytes - 1], (kBlobChunkBytes - 1) % 251);
    expect(bytes[kBlobChunkBytes], kBlobChunkBytes % 251);
    expect(bytes[kBlobChunkBytes * 2 - 1], (kBlobChunkBytes * 2 - 1) % 251);
    expect(bytes[kBlobChunkBytes * 2], (kBlobChunkBytes * 2) % 251);
    expect(bytes[totalBytes - 1], (totalBytes - 1) % 251);
  });

  testWidgets('扫描达到 maxScreens 上限时提前停下并提交 limit 进度', (tester) async {
    final started = DateTime.now();
    final harness = await _pumpFixture(tester, maxScreens: 2);

    await _waitFor(
      tester,
      () => harness.scanTerminal.isCompleted,
      const Duration(seconds: 60),
    );
    final elapsed = DateTime.now().difference(started);

    expect(harness.progresses.first.state, ScanState.start);
    expect(harness.progresses.last.state, ScanState.limit);
    expect(harness.progresses.last.screen, 2);
    expect(harness.progresses.last.maxScreens, 2);
    expect(harness.capture.scanReachedLimit, isTrue);
    expect(harness.capture.isScanning, isFalse);
    expect(
      elapsed,
      lessThan(const Duration(seconds: 30)),
      reason: '2 屏撞上限就该提前收工，不是等满 60s 超时',
    );
  });
}
