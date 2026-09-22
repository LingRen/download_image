import 'dart:convert';

import '../model/image_asset.dart';

/// JS 侧注册的 handler 名，抓取与下载共用这一个通道。
const String kBridgeHandlerName = 'imgcat';

/// blob 分块大小：512KB（分块是为了避免大图 base64 全量驻留内存）。
const int kBlobChunkBytes = 512 * 1024;

/// 扫描上限（设计文档第 6 节）：到达任一上限即停止。
const int kMaxScanScreens = 40;
const Duration kScanTimeout = Duration(seconds: 60);

enum ScanState { start, progress, done, limit, aborted }

/// JS → Dart 的消息。解析失败一律返回 null，不向上抛异常。
sealed class BridgeMessage {
  const BridgeMessage();

  static BridgeMessage? parse(Object? raw) {
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! Map) return null;
      final map = decoded.map((key, value) => MapEntry(key.toString(), value));
      switch (map['type']) {
        case 'batch':
          return CaptureBatch.fromMap(map);
        case 'scan':
          return ScanProgress.fromMap(map);
        case 'blob':
          return BlobChunk.fromMap(map);
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }
}

/// 增量推送的一批图片：每发现一批就推一次，不等扫完。
class CaptureBatch extends BridgeMessage {
  const CaptureBatch({required this.pageUrl, required this.assets});

  final String pageUrl;
  final List<ImageAsset> assets;

  factory CaptureBatch.fromMap(Map<String, Object?> map) {
    final rawAssets = map['assets'];
    final assets = <ImageAsset>[];
    if (rawAssets is List) {
      for (final item in rawAssets) {
        if (item is Map) {
          final json = item.map((key, value) => MapEntry(key.toString(), value));
          if (json['url'] is String) assets.add(ImageAsset.fromJson(json));
        }
      }
    }
    return CaptureBatch(pageUrl: map['pageUrl'] as String? ?? '', assets: assets);
  }
}

/// 自动扫整页的进度。
class ScanProgress extends BridgeMessage {
  const ScanProgress({
    required this.state,
    this.pageUrl = '',
    this.screen = 0,
    this.maxScreens = kMaxScanScreens,
    this.found = 0,
  });

  final ScanState state;
  final String pageUrl;

  /// 已滚动的屏数。
  final int screen;
  final int maxScreens;
  final int found;

  bool get isRunning => state == ScanState.start || state == ScanState.progress;

  factory ScanProgress.fromMap(Map<String, Object?> map) {
    final name = map['state'] as String?;
    return ScanProgress(
      state: ScanState.values.firstWhere(
        (value) => value.name == name,
        orElse: () => ScanState.done,
      ),
      pageUrl: map['pageUrl'] as String? ?? '',
      screen: (map['screen'] as num?)?.toInt() ?? 0,
      maxScreens: (map['maxScreens'] as num?)?.toInt() ?? kMaxScanScreens,
      found: (map['found'] as num?)?.toInt() ?? 0,
    );
  }
}

/// blob 通道的一个分块。[error] 非空表示这一路失败，可以降级。
class BlobChunk extends BridgeMessage {
  const BlobChunk({
    required this.id,
    required this.seq,
    required this.data,
    required this.last,
    this.mime,
    this.error,
  });

  final String id;
  final int seq;
  final String data;
  final bool last;
  final String? mime;
  final String? error;

  factory BlobChunk.fromMap(Map<String, Object?> map) {
    return BlobChunk(
      id: map['id'] as String? ?? '',
      seq: (map['seq'] as num?)?.toInt() ?? 0,
      data: map['data'] as String? ?? '',
      last: map['last'] == true,
      mime: map['mime'] as String?,
      error: map['error'] as String?,
    );
  }
}