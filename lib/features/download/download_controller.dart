import 'package:flutter/foundation.dart';

import '../../core/bridge/bridge_protocol.dart';
import '../../core/model/image_asset.dart';
import 'download_service.dart';
import 'save_target.dart';
import 'webview_blob_fetcher.dart';

enum DownloadStatus { idle, running, done, failed }

class DownloadController extends ChangeNotifier {
  DownloadController({
    required this.executor,
    required this.blobSink,
    this.archiver,
  });

  /// 下载执行器（真实实现是 DownloadService）。
  final DownloadExecutor executor;

  /// blob 分块接收器（真实实现是 WebViewBlobFetcher）。
  final BlobChunkSink blobSink;

  /// 打包下载器（桌面端注入；为 null 时不可用）。
  final DownloadArchiver? archiver;

  final Map<String, DownloadStatus> _status = <String, DownloadStatus>{};
  final Map<String, String> _errors = <String, String>{};
  final Map<String, String> _locations = <String, String>{};
  final List<String> _failedUrls = <String>[];

  bool _busy = false;
  bool _archiving = false;
  int _completed = 0;
  int _total = 0;
  bool _permissionDenied = false;

  ArchiveOutcome? _archiveOutcome;
  String? _archiveError;

  bool get isBusy => _busy;
  int get completed => _completed;
  int get total => _total;

  /// 是否具备打包下载能力。
  bool get canArchive => archiver != null;

  /// 最近一次打包结果；未打包或失败时为 null。
  ArchiveOutcome? get lastArchiveOutcome => _archiveOutcome;

  /// 最近一次打包的错误信息；无错误时为 null。
  String? get archiveError => _archiveError;

  /// 本批（最近一次 downloadAll/retry）中任一项因权限被拒。
  bool get needsPermission => _permissionDenied;

  List<String> get failedUrls => List.unmodifiable(_failedUrls);

  DownloadStatus statusOf(String url) => _status[url] ?? DownloadStatus.idle;

  String? errorOf(String url) => _errors[url];

  String? locationOf(String url) => _locations[url];

  String get progressLabel {
    if (!_busy) return '';
    return _archiving ? '正在打包 $_completed/$_total' : '正在下载 $_completed/$_total';
  }

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
        _permissionDenied =
            _permissionDenied || (e is SaveException && e.needsPermission);
        if (!_failedUrls.contains(asset.url)) _failedUrls.add(asset.url);
      }
      _completed++;
      notifyListeners();
    }

    _busy = false;
    notifyListeners();
  }

  Future<void> retry(ImageAsset asset) => downloadAll(<ImageAsset>[asset]);

  /// 打包下载：逐张取图后打成一个 zip。单张失败只跳过，不中断整批。
  ///
  /// 与 [downloadAll] 共用 `_busy`，因此打包期间不会再触发单张下载或其他打包。
  /// 结果通过 [lastArchiveOutcome] / [archiveError] 回读（方法本身不抛异常）。
  Future<ArchiveOutcome?> downloadArchive(
    List<ImageAsset> assets, {
    required String archiveName,
  }) async {
    final archiver = this.archiver;
    if (_busy || assets.isEmpty || archiver == null) return null;
    _busy = true;
    _archiving = true;
    _total = assets.length;
    _completed = 0;
    _permissionDenied = false;
    _archiveOutcome = null;
    _archiveError = null;
    notifyListeners();

    ArchiveOutcome? outcome;
    try {
      outcome = await archiver.downloadArchive(
        assets,
        archiveName: archiveName,
        onProgress: (done, total) {
          _completed = done;
          _total = total;
          notifyListeners();
        },
      );
      _archiveOutcome = outcome;
    } catch (e) {
      _archiveError = e is SaveException ? e.message : e.toString();
      _permissionDenied =
          _permissionDenied || (e is SaveException && e.needsPermission);
    } finally {
      _busy = false;
      _archiving = false;
      notifyListeners();
    }
    return outcome;
  }

  Future<void> openPermissionSettings() => executor.openPermissionSettings();
}
