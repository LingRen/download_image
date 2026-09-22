import 'dart:async';
import 'dart:io';

import '../../core/bridge/bridge_protocol.dart';
import '../../core/bridge/js_channel.dart';
import '../../core/model/image_asset.dart';
import 'blob_file_writer.dart';

/// blob 通道失败（HTTP 错误、桥超时等），调用方据此降级到原生直下。
class BlobFetchException implements Exception {
  BlobFetchException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// blob 分块接收器的最小接口：下载控制器只依赖它，测试可轻松替换。
abstract class BlobChunkSink {
  Future<void> accept(BlobChunk chunk);
}

/// 在页面内 `fetch` 取图片，512KB 分块回传并写进临时文件。
/// 一次只处理一个下载（下载队列本身就是串行的）。
class WebViewBlobFetcher implements BlobChunkSink {
  WebViewBlobFetcher(this.channel);

  final JsChannel channel;

  BlobFileWriter? _writer;
  Completer<File>? _completer;
  String? _activeId;
  int _counter = 0;

  Future<File> fetchToFile(ImageAsset asset, File destination) async {
    if (_writer != null) {
      throw BlobFetchException('已有 blob 下载在进行');
    }
    final id = 'dl-${DateTime.now().microsecondsSinceEpoch}-${_counter++}';
    final writer = BlobFileWriter(destination);
    await writer.open();
    _writer = writer;
    _activeId = id;
    final completer = Completer<File>();
    _completer = completer;

    try {
      await channel.call('fetchAsBase64', {
        'url': asset.url,
        'id': id,
        'chunkSize': kBlobChunkBytes,
      });
    } catch (e) {
      await _reset();
      throw BlobFetchException('调用页面内 fetch 失败：$e');
    }

    try {
      return await completer.future.timeout(const Duration(seconds: 45));
    } on TimeoutException {
      await _reset();
      throw BlobFetchException('blob 通道超时');
    }
  }

  /// 这里不做「字节数比对」：`JsChannel.call` 返回 `Future<void>`，桥只
  /// `evaluateJavascript` 且丢弃返回值、不等待页面内 Promise，拿不到总长度。
  /// 截断改为由三条更强且可验证的机制覆盖：
  /// ① `BlobFileWriter.add` 严格校验 seq 连续，缺块/重块/乱序都抛 StateError；
  /// ② 本方法把它立刻转成 BlobFetchException，立即降级原生而非等超时；
  /// ③ 最后一块始终没到 → `fetchToFile` 的 45s 超时兜底。
  /// BrowserPage 把 BlobChunk 消息转进来。
  @override
  Future<void> accept(BlobChunk chunk) async {
    final writer = _writer;
    if (writer == null || chunk.id != _activeId) return;
    if (chunk.error != null) {
      final completer = _completer;
      await _reset();
      completer?.completeError(BlobFetchException('页面内 fetch 失败：${chunk.error}'));
      return;
    }
    try {
      await writer.add(chunk);
    } catch (e) {
      // 回调不 await（void Function(BlobChunk)），异常会漏给平台通道，
      // 所以在此内部兜住并快速失败：清理临时文件后立即降级原生。
      final completer = _completer;
      await _reset();
      completer?.completeError(BlobFetchException('分块接收失败：$e'));
      return;
    }
    if (writer.isComplete) {
      final file = writer.file;
      final completer = _completer;
      await _reset(keepFile: true);
      completer?.complete(file);
    }
  }

  Future<void> _reset({bool keepFile = false}) async {
    final writer = _writer;
    _writer = null;
    _activeId = null;
    _completer = null;
    if (writer != null) {
      await writer.close();
      if (!keepFile) {
        try {
          if (await writer.file.exists()) await writer.file.delete();
        } catch (_) {
          // 清理失败不影响主流程
        }
      }
    }
  }
}