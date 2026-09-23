import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/model/image_asset.dart';
import 'file_name.dart';
import 'native_fetcher.dart';
import 'save_target.dart';
import 'webview_blob_fetcher.dart';
import 'zip_packager.dart';

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

/// 一次打包下载的结果。
class ArchiveOutcome {
  const ArchiveOutcome({
    required this.location,
    required this.included,
    required this.failed,
    required this.bytes,
  });

  /// 压缩包的落盘位置。
  final String location;

  /// 成功打进包里的张数。
  final int included;

  /// 取图失败被跳过的张数。
  final int failed;

  /// 压缩包字节数。
  final int bytes;
}

/// 下载控制器依赖的最小接口，便于测试替换。
abstract class DownloadExecutor {
  Future<DownloadOutcome> download(ImageAsset asset);

  Future<void> openPermissionSettings();
}

/// 打包下载接口（桌面端）；移动端不实现。
abstract class DownloadArchiver {
  Future<ArchiveOutcome> downloadArchive(
    List<ImageAsset> assets, {
    required String archiveName,
    void Function(int done, int total)? onProgress,
  });
}

class DownloadService implements DownloadExecutor, DownloadArchiver {
  DownloadService({
    required this.blobFetcher,
    required this.saveTarget,
    NativeFetcher? nativeFetcher,
    Future<Directory> Function()? tempDirectory,
    this.zipPackager = const ZipPackager(),
    this.refererProvider,
  }) : _nativeFetcher = nativeFetcher ?? NativeFetcher(),
       _tempDirectory = tempDirectory ?? getTemporaryDirectory;

  final WebViewBlobFetcher blobFetcher;
  final SaveTarget saveTarget;
  final NativeFetcher _nativeFetcher;
  final Future<Directory> Function() _tempDirectory;
  final ZipPackager zipPackager;

  /// 页面 URL，用作下载请求的 Referer。
  final String? Function()? refererProvider;

  @override
  Future<DownloadOutcome> download(ImageAsset asset) async {
    final fileName = buildFileName(asset.url, mimeType: asset.mimeType);
    final tempDir = await _tempDirectory();
    final tempFile = File(p.join(tempDir.path, 'imgcat_$fileName'));

    try {
      final usedFallback = await _fetchInto(asset, tempFile);
      final bytes = await tempFile.length();
      final location = await saveTarget.save(
        tempFile: tempFile,
        fileName: fileName,
        mimeType: asset.mimeType,
      );
      return DownloadOutcome(
        location: location,
        usedFallback: usedFallback,
        bytes: bytes,
      );
    } finally {
      // save 读的是 tempFile（桌面端 copy、移动端 Gal 按路径读），必须等它完成后再删；
      // 失败路径同样要清理，否则批量下载+重试会持续堆积临时文件。
      await _deleteQuietly(tempFile);
    }
  }

  /// 逐张取图到临时目录后打成一个 zip 存进系统下载目录。
  ///
  /// 单张失败只跳过并计数，不中断整批；全部失败才抛错。临时目录无论成败都清理。
  @override
  Future<ArchiveOutcome> downloadArchive(
    List<ImageAsset> assets, {
    required String archiveName,
    void Function(int done, int total)? onProgress,
  }) async {
    if (assets.isEmpty) {
      throw SaveException('没有可打包的图片');
    }
    final tempDir = await _tempDirectory();
    final workDir = Directory(
      p.join(tempDir.path, 'imgcat_zip_${DateTime.now().microsecondsSinceEpoch}'),
    );
    await workDir.create(recursive: true);

    try {
      final usedNames = <String>{};
      final entries = <ZipEntry>[];
      var failed = 0;
      var done = 0;

      for (final asset in assets) {
        final fileName = buildFileName(asset.url, mimeType: asset.mimeType);
        // 包内重名（不同图床的 image.png）自动降级为 image (1).png。
        final name = resolveFileName(fileName, usedNames.contains);
        final file = File(p.join(workDir.path, name));
        try {
          await _fetchInto(asset, file);
          usedNames.add(name);
          entries.add(ZipEntry(file: file, name: name));
        } catch (_) {
          failed++;
        }
        done++;
        onProgress?.call(done, assets.length);
      }

      if (entries.isEmpty) {
        throw SaveException('全部图片下载失败，未生成压缩包');
      }

      final zipFile = File(p.join(workDir.path, archiveName));
      await zipPackager.pack(destination: zipFile, entries: entries);
      final bytes = await zipFile.length();
      final location = await saveTarget.save(
        tempFile: zipFile,
        fileName: archiveName,
        mimeType: 'application/zip',
      );
      return ArchiveOutcome(
        location: location,
        included: entries.length,
        failed: failed,
        bytes: bytes,
      );
    } finally {
      try {
        if (await workDir.exists()) await workDir.delete(recursive: true);
      } catch (_) {
        // 工作目录清理失败不影响结果
      }
    }
  }

  /// 取一张图到 [destination]；返回是否走了原生降级通道。
  ///
  /// 只有 blob 通道自身失败才降级：临时目录不可写等系统级错误原样冒泡，
  /// 否则原生通道写同一路径同样会失败，真实原因会被掩盖。
  Future<bool> _fetchInto(ImageAsset asset, File destination) async {
    try {
      await blobFetcher.fetchToFile(asset, destination);
      return false;
    } on BlobFetchException catch (_) {
      await _nativeFetcher.fetchToFile(
        asset,
        destination,
        referer: refererProvider?.call(),
      );
      return true;
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 清理失败不影响主流程
    }
  }

  @override
  Future<void> openPermissionSettings() => saveTarget.openPermissionSettings();
}
