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
/// 期望值（草稿用的假域名会让所有图 404，尺寸变成 null，尺寸过滤断言必然失败）。
const String _fixtureHtml = '''
<!DOCTYPE html><html><head><style>
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
  <div style="height: 4000px"></div>
  <div id="late"></div>
  <script>
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

/// 路径 → 图片内在尺寸。只列真实存在的图片；`/img/d-small.webp` 与
/// `/img/d-large.webp` 故意返回 404（srcset 用例只看 URL，不看是否加载成功）。
const Map<String, List<int>> _imageSpec = {
  '/img/a.jpg': [300, 200],
  '/img/b.png': [120, 120],
  '/img/c.gif': [1, 1],
  '/img/bg-1.png': [200, 200],
  '/img/bg-2.jpg': [200, 200],
  '/img/lazy-e.jpg': [240, 240],
  '/img/scroll-f.jpg': [260, 260],
};

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
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('JS 抓取脚本的增量推送、扫描进度与 blob 分块通道端到端打通', (tester) async {
    // ---------- fixture 服务器 ----------
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final origin = 'http://127.0.0.1:${server.port}';
    final fixtureUrl = '$origin/index.html';

    server.listen((request) async {
      final path = request.uri.path;
      final response = request.response;
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
    });

    final expectedUrls = {
      '$origin/img/a.jpg',
      '$origin/img/b.png',
      '$origin/img/c.gif',
      '$origin/img/d-large.webp',
      '$origin/img/bg-1.png',
      '$origin/img/bg-2.jpg',
      '$origin/img/lazy-e.jpg',
      '$origin/img/scroll-f.jpg',
    };

    // ---------- 装配 WebView 与桥 ----------
    final capture = CaptureController();
    final jsChannel = JsChannelHolder();
    final batches = <CaptureBatch>[];
    final progresses = <ScanProgress>[];
    final blobChunks = <BlobChunk>[];
    final scanTerminal = Completer<void>();
    late InAppWebViewController controller;

    await tester.pumpWidget(MaterialApp(
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
            controller = created;
            jsChannel.attach(WebViewJsChannel(created));
            created.addJavaScriptHandler(
              handlerName: kBridgeHandlerName,
              callback: (args) {
                final message =
                    BridgeMessage.parse(args.isNotEmpty ? args.first : null);
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
                  'window.__imgcat.scan({"maxScreens": 40, "timeoutMs": 60000});',
            );
          },
        ),
      ),
    ));

    await _waitFor(tester, () => scanTerminal.isCompleted,
        const Duration(seconds: 60));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 1));

    // ---------- 增量推送：扫描后页面又出现新图，必须再推一批（只含新图） ----------
    await controller.evaluateJavascript(source: '''
      (function () {
        var img = document.createElement('img');
        img.src = '/img/scroll-f.jpg';
        img.width = 260; img.height = 260;
        document.getElementById('late').appendChild(img);
      })();
    ''');
    await _waitFor(tester, () => batches.length >= 2,
        const Duration(seconds: 15));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 1));

    expect(batches.length, greaterThanOrEqualTo(2),
        reason: '每发现一批就推一次，不能扫完才一次性推');
    expect(batches.last.assets.map((asset) => asset.url).toList(),
        ['$origin/img/scroll-f.jpg'],
        reason: '增量批只包含新发现的图，不能重推全量快照');
    expect(batches.every((batch) => batch.pageUrl == fixtureUrl), isTrue,
        reason: '每批增量都带当前页 URL');

    // ---------- 扫描进度序列 ----------
    expect(progresses, isNotEmpty);
    expect(progresses.first.state, ScanState.start);
    expect(progresses.any((p) => p.state == ScanState.done), isTrue);
    expect(progresses.last.state, anyOf(ScanState.done, ScanState.limit));
    expect(progresses.last.isRunning, isFalse);
    expect(progresses.every((p) => p.pageUrl == fixtureUrl), isTrue,
        reason: 'ScanProgress.pageUrl 必须是 fixture 的真实 URL');

    // ---------- Dart 侧 URL 集合 ----------
    final dartUrls = capture.rawAssets.map((asset) => asset.url).toSet();
    expect(dartUrls, expectedUrls,
        reason: 'Dart 侧拿到的 URL 集合必须与 fixture 完全一致');
    expect(capture.pageUrl, fixtureUrl);

    // ---------- 桥不丢消息：与 JS 侧聚合结果完全相等 ----------
    final jsAssetsRaw = await controller.evaluateJavascript(
      source: 'JSON.stringify(window.__imgcat.assets())',
    );
    final jsUrls =
        (jsonDecode(jsAssetsRaw as String) as List).cast<String>().toSet();
    expect(jsUrls, expectedUrls, reason: 'JS 侧聚合集合必须与预期一致');
    expect(jsUrls, dartUrls, reason: '桥不能丢消息');

    // ---------- 来源与尺寸语义（真实加载后的内在尺寸） ----------
    final byUrl = {for (final asset in capture.rawAssets) asset.url: asset};

    final aJpg = byUrl['$origin/img/a.jpg']!;
    expect(aJpg.width, 300);
    expect(aJpg.height, 200);
    expect(aJpg.sizeKnown, isTrue);

    final dLarge = byUrl['$origin/img/d-large.webp']!;
    expect(dLarge.source, ImageSource.srcset);
    expect(dLarge.width, 1200);
    expect(dLarge.height, isNull);
    expect(dLarge.sizeKnown, isFalse, reason: 'srcset 只给宽度，尺寸未知');

    expect(byUrl['$origin/img/bg-1.png']!.source, ImageSource.cssBackground);
    expect(byUrl['$origin/img/bg-2.jpg']!.source, ImageSource.cssBackground);
    expect(byUrl['$origin/img/lazy-e.jpg']!.width, 240);
    expect(byUrl['$origin/img/lazy-e.jpg']!.height, 240);

    // ---------- 筛选：1×1 真的被尺寸滤镜挡掉 ----------
    final cGif = byUrl['$origin/img/c.gif']!;
    expect(cGif.sizeKnown, isTrue, reason: '1×1 gif 必须真的解码出尺寸');
    expect(cGif.width, 1);
    expect(cGif.height, 1);
    expect(isFilteredOut(cGif, capture.filter), isTrue,
        reason: '1×1 必须被尺寸滤镜过滤');
    expect(capture.rawCount, expectedUrls.length, reason: 'rawAssets 不做筛选');

    final visible = capture.visibleAssets;
    expect(visible.any((asset) => asset.url == cGif.url), isFalse,
        reason: '1×1 像素必须被过滤');
    expect(visible.any((asset) => asset.url == aJpg.url), isTrue);
    expect(visible.where((asset) => asset.url == dLarge.url).length, 1,
        reason: 'srcset 只保留最大候选，小候选不能重复出现；尺寸未知的不过滤');

    // ---------- 扫描态复位（Task 17 遗留：removeUrls 不碰 _scan） ----------
    expect(capture.isScanning, isFalse);
    expect(capture.scanReachedLimit, isFalse);

    capture.keepAssetsForNewPage('$origin/other.html');
    expect(capture.isScanning, isFalse, reason: '换页保留时必须复位扫描态');
    expect(capture.rawCount, expectedUrls.length, reason: '保留分支不能丢图');

    capture.removeUrls(dartUrls);
    expect(capture.rawCount, 0);
    expect(capture.isScanning, isFalse, reason: '清空后不能把 _scan 留在 running');

    // ---------- blob 分块通道端到端 ----------
    final tempDir = Directory.systemTemp.createTempSync('imgcat_it');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final destination = File('${tempDir.path}/blob.bin');
    final writer = BlobFileWriter(destination);
    await writer.open();

    const totalBytes = 1200000;
    await controller.evaluateJavascript(source: '''
      (function () {
        var bytes = new Uint8Array($totalBytes);
        for (var i = 0; i < bytes.length; i++) { bytes[i] = i % 251; }
        window.__imgcatTestBlobUrl =
          URL.createObjectURL(new Blob([bytes], { type: 'image/png' }));
        window.__imgcat.fetchAsBase64({
          url: window.__imgcatTestBlobUrl, id: 'it-1', chunkSize: $kBlobChunkBytes
        });
      })();
    ''');

    List<BlobChunk> mine() =>
        blobChunks.where((chunk) => chunk.id == 'it-1').toList();
    await _waitFor(
        tester, () => mine().isNotEmpty && mine().last.last,
        const Duration(seconds: 45));

    final chunks = mine();
    // 分块协议：mime 是图片类型、seq 从 0 连续递增、只有最后一块 last == true。
    expect(chunks.length, (totalBytes / kBlobChunkBytes).ceil());
    expect(chunks.map((chunk) => chunk.seq).toList(),
        List<int>.generate(chunks.length, (index) => index));
    expect(chunks.where((chunk) => chunk.last).length, 1);
    expect(chunks.last.last, isTrue);
    expect(chunks.every((chunk) => chunk.error == null), isTrue);
    expect(chunks.first.mime, 'image/png');
    expect(chunks.every((chunk) => chunk.mime == 'image/png'), isTrue);

    for (final chunk in chunks) {
      await writer.add(chunk);
    }
    await writer.close();

    expect(writer.isComplete, isTrue);
    expect(writer.receivedBytes, totalBytes);
    expect(await destination.length(), totalBytes);
    final bytes = await destination.readAsBytes();
    expect(bytes[0], 0);
    expect(bytes[250], 250);
    expect(bytes[251], 0);
    expect(bytes[totalBytes - 1], (totalBytes - 1) % 251);
  });
}