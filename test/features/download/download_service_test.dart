import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:download_image/core/bridge/js_channel.dart';
import 'package:download_image/core/model/image_asset.dart';
import 'package:download_image/features/download/download_service.dart';
import 'package:download_image/features/download/native_fetcher.dart';
import 'package:download_image/features/download/save_target.dart';
import 'package:download_image/features/download/webview_blob_fetcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假桥：本文件里 fetchToFile 已被子类覆写，不会真的走平台通道。
class _NoopJsChannel implements JsChannel {
  const _NoopJsChannel();

  @override
  Future<void> call(String function, Map<String, Object?> args) async {}
}

/// 用子类覆写 fetchToFile 伪造 blob 通道的结果。
class _StubBlobFetcher extends WebViewBlobFetcher {
  _StubBlobFetcher(this.handler) : super(const _NoopJsChannel());

  final Future<File> Function(ImageAsset asset, File destination) handler;

  @override
  Future<File> fetchToFile(ImageAsset asset, File destination) =>
      handler(asset, destination);
}

/// 记录调用次数并可控失败的原生通道替身。
class _StubNativeFetcher extends NativeFetcher {
  _StubNativeFetcher({this.failure});

  final Exception? failure;
  final List<String> calls = <String>[];

  @override
  Future<File> fetchToFile(
    ImageAsset asset,
    File destination, {
    String? referer,
    void Function(int received, int? total)? onProgress,
  }) async {
    calls.add(asset.url);
    final error = failure;
    if (error != null) throw error;
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(<int>[9, 9, 9]);
    return destination;
  }
}

ImageAsset _asset() =>
    const ImageAsset(url: 'https://a.com/p.jpg', mimeType: 'image/jpeg');

void main() {
  late Directory tempDir;
  late Directory downloadsDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dl_service_temp');
    downloadsDir = await Directory.systemTemp.createTemp('dl_service_out');
  });

  tearDown(() async {
    for (final dir in <Directory>[tempDir, downloadsDir]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  DownloadService build({
    required Future<File> Function(ImageAsset, File) blob,
    NativeFetcher? nativeFetcher,
  }) {
    return DownloadService(
      blobFetcher: _StubBlobFetcher(blob),
      saveTarget: DownloadsSaveTarget(
        downloadsDirectory: () async => downloadsDir,
      ),
      nativeFetcher: nativeFetcher ?? _StubNativeFetcher(),
      tempDirectory: () async => tempDir,
    );
  }

  File tempFile() => File('${tempDir.path}/imgcat_p.jpg');

  File savedFile() => File('${downloadsDir.path}/p.jpg');

  test('blob 成功：不降级、内容来自 blob、临时文件已清理', () async {
    final native = _StubNativeFetcher();
    final service = build(
      blob: (asset, dest) async {
        await dest.parent.create(recursive: true);
        await dest.writeAsBytes(<int>[1, 2, 3, 4]);
        return dest;
      },
      nativeFetcher: native,
    );

    final outcome = await service.download(_asset());

    expect(outcome.usedFallback, isFalse);
    expect(outcome.bytes, 4);
    expect(outcome.location, savedFile().path);
    expect(await savedFile().readAsBytes(), <int>[1, 2, 3, 4]);
    expect(native.calls, isEmpty);
    expect(await tempFile().exists(), isFalse);
  });

  test('blob 抛 BlobFetchException：降级原生且落盘内容来自原生侧', () async {
    final native = _StubNativeFetcher();
    final service = build(
      blob: (asset, dest) async {
        await dest.parent.create(recursive: true);
        await dest.writeAsBytes(<int>[1, 1, 1, 1]);
        throw BlobFetchException('blob 通道超时');
      },
      nativeFetcher: native,
    );

    final outcome = await service.download(_asset());

    expect(outcome.usedFallback, isTrue);
    expect(native.calls, ['https://a.com/p.jpg']);
    expect(await savedFile().readAsBytes(), <int>[9, 9, 9]);
    expect(outcome.bytes, 3);
    expect(await tempFile().exists(), isFalse);
  });

  test('两端都失败：抛原生侧异常且临时文件已清理', () async {
    final native = _StubNativeFetcher(
      failure: NativeFetchException('原生直下失败：403'),
    );
    final service = build(
      blob: (asset, dest) async {
        await dest.parent.create(recursive: true);
        await dest.writeAsBytes(<int>[1, 1]);
        throw BlobFetchException('页面内 fetch 失败：HTTP 404');
      },
      nativeFetcher: native,
    );

    await expectLater(
      service.download(_asset()),
      throwsA(isA<NativeFetchException>()),
    );
    expect(native.calls.length, 1);
    expect(await tempFile().exists(), isFalse);
  });

  test('系统级异常不触发降级：原样冒泡且不调用原生侧', () async {
    final native = _StubNativeFetcher();
    final service = build(
      blob: (asset, dest) {
        throw const FileSystemException('临时目录不可写');
      },
      nativeFetcher: native,
    );

    await expectLater(
      service.download(_asset()),
      throwsA(isA<FileSystemException>()),
    );
    expect(native.calls, isEmpty);
  });

  group('downloadArchive', () {
    test('成功：包内重名自动去重、存进下载目录、工作目录已清理', () async {
      final service = build(
        blob: (asset, dest) async {
          await dest.parent.create(recursive: true);
          await dest.writeAsBytes(utf8.encode(asset.url));
          return dest;
        },
      );
      const assets = [
        ImageAsset(url: 'https://a.com/img/p.jpg'),
        ImageAsset(url: 'https://b.com/img/p.jpg'),
      ];
      final progress = <String>[];

      final outcome = await service.downloadArchive(
        assets,
        archiveName: 'imgcat-x.zip',
        onProgress: (done, total) => progress.add('$done/$total'),
      );

      expect(outcome.included, 2);
      expect(outcome.failed, 0);
      expect(progress, ['1/2', '2/2']);

      final zip = File('${downloadsDir.path}/imgcat-x.zip');
      expect(outcome.location, zip.path);
      expect(await zip.exists(), isTrue);

      final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
      final names = archive.files.map((file) => file.name).toList()..sort();
      expect(names, ['p (1).jpg', 'p.jpg']);
      expect(
        archive.findFile('p.jpg')!.content,
        utf8.encode('https://a.com/img/p.jpg'),
      );
      expect(outcome.bytes, await zip.length());

      final leftovers = tempDir
          .listSync()
          .where((entry) => entry.path.contains('imgcat_zip_'));
      expect(leftovers, isEmpty, reason: '打包工作目录必须清理');
    });

    test('单张失败只跳过并计数，其余仍然打包', () async {
      final service = build(
        blob: (asset, dest) async {
          if (asset.url.contains('bad')) {
            // 非 BlobFetchException 不降级，直接算这一张失败。
            throw const FileSystemException('404');
          }
          await dest.parent.create(recursive: true);
          await dest.writeAsBytes(const [1, 2, 3]);
          return dest;
        },
      );

      final outcome = await service.downloadArchive(
        [
          const ImageAsset(url: 'https://a.com/bad.jpg'),
          const ImageAsset(url: 'https://a.com/ok.jpg'),
        ],
        archiveName: 'imgcat-y.zip',
      );

      expect(outcome.included, 1);
      expect(outcome.failed, 1);
      final archive = ZipDecoder().decodeBytes(
        await File('${downloadsDir.path}/imgcat-y.zip').readAsBytes(),
      );
      expect(archive.files.map((file) => file.name), ['ok.jpg']);
    });

    test('全部失败：抛错且不生成 zip', () async {
      final service = build(
        blob: (asset, dest) => throw const FileSystemException('404'),
      );

      await expectLater(
        service.downloadArchive(
          [const ImageAsset(url: 'https://a.com/bad.jpg')],
          archiveName: 'imgcat-z.zip',
        ),
        throwsA(isA<SaveException>()),
      );
      expect(await File('${downloadsDir.path}/imgcat-z.zip').exists(), isFalse);
    });

    test('空列表：直接抛「没有可打包的图片」', () async {
      final service = build(
        blob: (asset, dest) async => dest,
      );

      await expectLater(
        service.downloadArchive(
          [],
          archiveName: 'imgcat-empty.zip',
        ),
        throwsA(
          isA<SaveException>().having(
            (e) => e.message,
            'message',
            '没有可打包的图片',
          ),
        ),
      );
    });
  });
}
