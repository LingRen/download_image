import 'package:flutter/foundation.dart';

import '../../core/bridge/bridge_protocol.dart';
import '../../core/model/image_asset.dart';
import 'deduplicator.dart';
import 'image_filter.dart';

/// 抓取结果聚合器：把桥消息变成可渲染的列表。
///
/// 选中态也放在这里：它和列表数据同源，单独再开一个控制器没有收益（YAGNI）。
class CaptureController extends ChangeNotifier {
  final Map<String, ImageAsset> _byUrl = <String, ImageAsset>{};

  FilterSettings _filter = const FilterSettings();
  ScanProgress? _scan;
  bool _reachedLimit = false;
  String? _pageUrl;
  final Set<String> _selected = <String>{};

  int notifyCount = 0;

  @override
  void notifyListeners() {
    notifyCount++;
    super.notifyListeners();
  }

  List<ImageAsset> get rawAssets => List.unmodifiable(_byUrl.values);

  int get rawCount => _byUrl.length;

  FilterSettings get filter => _filter;

  /// 筛选是否仍为默认值（决定筛选栏是否显示「重置」）。
  bool get isFilterDefault => _filter.isDefault;

  ScanProgress? get scan => _scan;

  /// 上一次扫描是否撞到 40 屏 / 60 秒上限。
  bool get scanReachedLimit => _reachedLimit;

  bool get isScanning => _scan?.isRunning ?? false;

  /// 结果所属页面 URL，用于「已切换页面」判断。
  String? get pageUrl => _pageUrl;

  Set<String> get selectedUrls => Set.unmodifiable(_selected);

  /// 应用筛选 + 两级去重后的列表。顺序即发现顺序。
  List<ImageAsset> get visibleAssets {
    final kept = _byUrl.values
        .where((asset) => !isFilteredOut(asset, _filter))
        .toList();
    return deduplicate(kept, mergeVariants: _filter.mergeVariants);
  }

  /// 选中且当前仍然可见的图片，下载只处理这些。
  List<ImageAsset> get selectedAssets {
    final selected = visibleAssets
        .where((asset) => _selected.contains(asset.url))
        .toList();
    return selected;
  }

  void accept(BridgeMessage message) {
    switch (message) {
      case CaptureBatch batch:
        if (batch.pageUrl.isNotEmpty) _pageUrl = batch.pageUrl;
        for (final asset in batch.assets) {
          final existing = _byUrl[asset.url];
          _byUrl[asset.url] = existing == null ? asset : existing.merge(asset);
        }
        notifyListeners();
      case ScanProgress progress:
        if (progress.pageUrl.isNotEmpty) _pageUrl = progress.pageUrl;
        if (progress.state == ScanState.start) _reachedLimit = false;
        if (progress.state == ScanState.limit) _reachedLimit = true;
        _scan = progress;
        notifyListeners();
      case BlobChunk():
        // blob 分块由 DownloadController 处理，聚合器不关心。
        break;
    }
  }

  /// 恢复默认筛选（尺寸去重开、最小边 64px、全部格式与来源）。
  void resetFilter() {
    if (_filter.isDefault) return;
    _filter = const FilterSettings();
    notifyListeners();
  }

  void setMinSide(int value) {
    _filter = _filter.copyWith(minSide: value);
    notifyListeners();
  }

  void toggleFormat(String format) {
    final formats = Set<String>.from(_filter.enabledFormats);
    if (!formats.remove(format)) formats.add(format);
    _filter = _filter.copyWith(enabledFormats: formats);
    notifyListeners();
  }

  void setMergeVariants(bool value) {
    _filter = _filter.copyWith(mergeVariants: value);
    notifyListeners();
  }

  void setSources(Set<ImageSource> sources) {
    _filter = _filter.copyWith(enabledSources: sources);
    notifyListeners();
  }

  void toggleSource(ImageSource source) {
    final sources = Set<ImageSource>.from(_filter.enabledSources);
    if (!sources.remove(source)) sources.add(source);
    _filter = _filter.copyWith(enabledSources: sources);
    notifyListeners();
  }

  void toggleSelection(String url) {
    if (!_selected.remove(url)) _selected.add(url);
    notifyListeners();
  }

  void selectAllVisible() {
    _selected
      ..clear()
      ..addAll(visibleAssets.map((asset) => asset.url));
    notifyListeners();
  }

  void clearSelection() {
    _selected.clear();
    notifyListeners();
  }

  /// 只删这几个 URL（切换页面时用户选择「清空」）。
  ///
  /// 不用 clear()：新页 DOM 解析后约 300ms 抓取脚本就会推一批图，等用户在对话框上
  /// 点「清空」时新页的图已经在 _byUrl 里了，一把清光会静默丢图。
  void removeUrls(Iterable<String> urls) {
    var changed = false;
    for (final url in urls) {
      if (_byUrl.remove(url) != null) changed = true;
      _selected.remove(url);
    }
    if (changed) notifyListeners();
  }

  /// 清空列表与选中态（切换页面时用户选择「清空」）。
  void clear() {
    _byUrl.clear();
    _selected.clear();
    _scan = null;
    _reachedLimit = false;
    _pageUrl = null;
    notifyListeners();
  }

  /// 只重置扫描状态，保留已抓列表（页面跳转时用户选择「保留」）。
  void keepAssetsForNewPage(String newPageUrl) {
    _pageUrl = newPageUrl;
    _scan = null;
    _reachedLimit = false;
    notifyListeners();
  }
}
