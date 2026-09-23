import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:download_image/core/bridge/bridge_protocol.dart';
import 'package:download_image/core/bridge/js_channel.dart';
import 'package:download_image/core/model/image_asset.dart';
import 'package:download_image/features/download/webview_blob_fetcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假桥：不发分块，只记录调用；分块由测试手动喂给接收器。
class _FakeJsChannel implements JsChannel {
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];
  final Completer<void> called = Completer<void>();

  @override
  Future<void> call(String function, Map<String, Object?> args) async {
    calls.add(args);
    if (!called.isCompleted) called.complete();
  }
}

ImageAsset _asset() =>
    const ImageAsset(url: 'https://a.com/p.jpg', width: 10, height: 10);

String _b64(List<int> bytes) => base64Encode(bytes);

void main() {
  late Directory dir;
  late File dest;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('blob_fetcher_test');
    dest = File('${dir.path}/out.bin');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// 起一次下载并等到桥被调用（此时接收器已记好 id），返回待完成的下载 Future 与 id。
  Future<(Future<File>, String)> start(
    WebViewBlobFetcher fetcher,
    _FakeJsChannel channel,
  ) async {
    final result = fetcher.fetchToFile(_asset(), dest);
    await channel.called.future;
    return (result, channel.calls.single['id'] as String);
  }

  test('正常分块序列写满后返回临时文件且字节数匹配', () async {
    final channel = _FakeJsChannel();
    final fetcher = WebViewBlobFetcher(channel);
    final (result, id) = await start(fetcher, channel);

    await fetcher.accept(
      BlobChunk(id: id, seq: 0, data: _b64(<int>[1, 2, 3]), last: false),
    );
    await fetcher.accept(
      BlobChunk(id: id, seq: 1, data: _b64(<int>[4, 5]), last: true),
    );

    final file = await result;
    expect(file.path, dest.path);
    expect(await file.length(), 5);
    expect(file.readAsBytesSync(), <int>[1, 2, 3, 4, 5]);
    expect(channel.calls.single['url'], 'https://a.com/p.jpg');
  });

  test('两块不 await 直接连发也不会被误判乱序', () async {
    final channel = _FakeJsChannel();
    final fetcher = WebViewBlobFetcher(channel);
    final (result, id) = await start(fetcher, channel);

    // 复刻平台通道的 fire-and-forget：第一块的 Future 被丢弃，紧接着发第二块。
    unawaited(
      fetcher.accept(
        BlobChunk(id: id, seq: 0, data: _b64(<int>[1, 2, 3]), last: false),
      ),
    );
    unawaited(
      fetcher.accept(
        BlobChunk(id: id, seq: 1, data: _b64(<int>[4, 5]), last: true),
      ),
    );

    final file = await result;
    expect(await file.length(), 5);
    expect(file.readAsBytesSync(), <int>[1, 2, 3, 4, 5]);
  });

  test('error 非空的分块抛 BlobFetchException 且不残留临时文件', () async {
    final channel = _FakeJsChannel();
    final fetcher = WebViewBlobFetcher(channel);
    final (result, id) = await start(fetcher, channel);
    final expectation = expectLater(result, throwsA(isA<BlobFetchException>()));

    await fetcher.accept(
      BlobChunk(id: id, seq: 0, data: '', last: false, error: 'HTTP 404'),
    );

    await expectation;
    expect(await dest.exists(), isFalse);
  });

  test('乱序分块立即抛 BlobFetchException 而不是漏出 StateError', () async {
    final channel = _FakeJsChannel();
    final fetcher = WebViewBlobFetcher(channel);
    final (result, id) = await start(fetcher, channel);
    final expectation = expectLater(result, throwsA(isA<BlobFetchException>()));

    // 先给 seq 1，writer.add 会抛 StateError，接收器须立刻转为 BlobFetchException。
    await fetcher.accept(
      BlobChunk(id: id, seq: 1, data: _b64(<int>[9]), last: false),
    );

    await expectation;
    expect(await dest.exists(), isFalse);
  });

  test('无进行中下载时 accept 静默返回不抛异常', () async {
    final channel = _FakeJsChannel();
    final fetcher = WebViewBlobFetcher(channel);

    await fetcher.accept(
      const BlobChunk(id: 'dl-none', seq: 0, data: '', last: true),
    );

    expect(channel.calls, isEmpty);
  });
}
