import 'package:flutter/foundation.dart';

import '../../core/bridge/bridge_protocol.dart';
import '../../core/model/image_asset.dart';
import 'download_service.dart';
import 'save_target.dart';
import 'webview_blob_fetcher.dart';

enum DownloadStatus { idle, running, done, failed }

class DownloadController extends ChangeNotifier {
  DownloadController({required this.executor, required this.blobSink});

  /// 下载执行器（真实实现是 DownloadService）。
  final DownloadExecutor executor;

  /// blob 分块接收器（真实实现是 WebViewBlobFetcher）。
  final BlobChunkSink blobSink;

  final Map<String, DownloadStatus> _status = <String, DownloadStatus>{};
  final Map<String, String> _errors = <String, String>{};
  final Map<String, String> _locations = <String, String>{};
  final List<String> _failedUrls = <String>[];

  bool _busy = false;
  int _completed = 0;
  int _total = 0;
  bool _permissionDenied = false;

  bool get isBusy => _busy;
  int get completed => _completed;
  int get total => _total;

  /// 最近一次下载因为权限被拒。
  bool get needsPermission => _permissionDenied;

  List<String> get failedUrls => List.unmodifiable(_failedUrls);

  DownloadStatus statusOf(String url) => _status[url] ?? DownloadStatus.idle;

  String? errorOf(String url) => _errors[url];

  String? locationOf(String url) => _locations[url];

  String get progressLabel => _busy ? '正在下载 $_completed/$_total' : '';

  /// BrowserPage 把 blob 分块转进来。
  Future<void> acceptBlobChunk(BlobChunk chunk) => blobSink.accept(chunk);

  /// 串行下载；单项失败不影响其他项（设计文档第 9 节）。
  Future<void> downloadAll(List<ImageAsset> assets) async {
    if (_busy || assets.isEmpty) return;
    _busy = true;
    _total = assets.length;
    _completed = 0;
    _permissionDenied = false;
    notifyListeners();

    for (final asset in assets) {
      _status[asset.url] = DownloadStatus.running;
      notifyListeners();
      try {
        final outcome = await executor.download(asset);
        _status[asset.url] = DownloadStatus.done;
        _locations[asset.url] = outcome.location;
        _errors.remove(asset.url);
        _failedUrls.remove(asset.url);
      } catch (e) {
        _status[asset.url] = DownloadStatus.failed;
        _errors[asset.url] = e is SaveException ? e.message : e.toString();
        _permissionDenied = _permissionDenied || (e is SaveException && e.needsPermission);
        if (!_failedUrls.contains(asset.url)) _failedUrls.add(asset.url);
      }
      _completed++;
      notifyListeners();
    }

    _busy = false;
    notifyListeners();
  }

  Future<void> retry(ImageAsset asset) => downloadAll(<ImageAsset>[asset]);

  Future<void> openPermissionSettings() => executor.openPermissionSettings();
}