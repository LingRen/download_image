import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/model/image_asset.dart';
import 'file_name.dart';
import 'native_fetcher.dart';
import 'save_target.dart';
import 'webview_blob_fetcher.dart';

/// 一次下载的结果。
class DownloadOutcome {
  const DownloadOutcome({
    required this.location,
    required this.usedFallback,
    required this.bytes,
  });

  /// 相册名或桌面绝对路径。
  final String location;

  /// 是否走了 Dio 原生降级通道。
  final bool usedFallback;

  /// 落盘字节数；原生通道未知时为 null。
  final int? bytes;
}

/// 下载控制器依赖的最小接口，便于测试替换。
abstract class DownloadExecutor {
  Future<DownloadOutcome> download(ImageAsset asset);

  Future<void> openPermissionSettings();
}

class DownloadService implements DownloadExecutor {
  DownloadService({
    required this.blobFetcher,
    required this.saveTarget,
    NativeFetcher? nativeFetcher,
    Future<Directory> Function()? tempDirectory,
    this.refererProvider,
  })  : _nativeFetcher = nativeFetcher ?? NativeFetcher(),
        _tempDirectory = tempDirectory ?? getTemporaryDirectory;

  final WebViewBlobFetcher blobFetcher;
  final SaveTarget saveTarget;
  final NativeFetcher _nativeFetcher;
  final Future<Directory> Function() _tempDirectory;

  /// 页面 URL，用作下载请求的 Referer。
  final String? Function()? refererProvider;

  @override
  Future<DownloadOutcome> download(ImageAsset asset) async {
    final fileName = buildFileName(asset.url, mimeType: asset.mimeType);
    final tempDir = await _tempDirectory();
    final tempFile = File(p.join(tempDir.path, 'imgcat_$fileName'));

    try {
      var usedFallback = false;
      int? bytes;
      try {
        final file = await blobFetcher.fetchToFile(asset, tempFile);
        bytes = await file.length();
      } on BlobFetchException catch (_) {
        // 只有 blob 通道自身失败才降级：临时目录不可写等系统级错误原样冒泡，
        // 否则原生通道写同一路径同样会失败，真实原因会被掩盖。
        usedFallback = true;
        final file = await _nativeFetcher.fetchToFile(
          asset,
          tempFile,
          referer: refererProvider?.call(),
        );
        bytes = await file.length();
      }

      final location = await saveTarget.save(
        tempFile: tempFile,
        fileName: fileName,
        mimeType: asset.mimeType,
      );
      return DownloadOutcome(location: location, usedFallback: usedFallback, bytes: bytes);
    } finally {
      // save 读的是 tempFile（桌面端 copy、移动端 Gal 按路径读），必须等它完成后再删；
      // 失败路径同样要清理，否则批量下载+重试会持续堆积临时文件。
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {
        // 临时文件清理失败不影响结果
      }
    }
  }

  @override
  Future<void> openPermissionSettings() => saveTarget.openPermissionSettings();
}
