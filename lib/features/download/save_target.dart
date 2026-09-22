import 'dart:io';

import 'package:app_settings/app_settings.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import 'file_name.dart';

/// 保存失败。[needsPermission] 为 true 时 UI 应引导用户去系统设置。
class SaveException implements Exception {
  SaveException(this.message, {this.needsPermission = false});

  final String message;
  final bool needsPermission;

  @override
  String toString() => message;
}

/// 在 [exists] 判定下挑一个不冲突的文件名。
String resolveFileName(String fileName, bool Function(String candidate) exists) {
  if (!exists(fileName)) return fileName;
  for (var index = 1; index < 1000; index++) {
    final candidate = uniqueFileName(fileName, index);
    if (!exists(candidate)) return candidate;
  }
  return uniqueFileName(fileName, DateTime.now().millisecondsSinceEpoch);
}

/// 保存目标的抽象：这是四端唯一的平台差异点。
abstract class SaveTarget {
  /// 返回保存后的可读位置描述（桌面是绝对路径，移动端是相册名）。
  Future<String> save({required File tempFile, required String fileName, String? mimeType});

  /// 引导用户去系统设置（移动端相册权限被拒时）。
  Future<void> openPermissionSettings();
}

/// 按当前平台选择保存目标。
SaveTarget createSaveTarget() {
  if (Platform.isAndroid || Platform.isIOS) return const GallerySaveTarget();
  return DownloadsSaveTarget();
}

/// 桌面端：写系统下载目录。
/// macOS 沙盒下依赖 `com.apple.security.files.downloads.read-write` entitlement，无需授权弹窗。
class DownloadsSaveTarget implements SaveTarget {
  DownloadsSaveTarget({Future<Directory?> Function()? downloadsDirectory})
      : _downloadsDirectory = downloadsDirectory ?? getDownloadsDirectory;

  final Future<Directory?> Function() _downloadsDirectory;

  @override
  Future<String> save({required File tempFile, required String fileName, String? mimeType}) async {
    try {
      final dir = await _downloadsDirectory();
      if (dir == null) {
        throw SaveException('无法定位系统下载目录');
      }
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final resolved = resolveFileName(fileName, (candidate) => File('${dir.path}/$candidate').existsSync());
      final target = File('${dir.path}/$resolved');
      await tempFile.copy(target.path);
      return target.path;
    } on SaveException {
      // 已是对外承诺的失败类型，原样透传，不再套一层前缀。
      rethrow;
    } catch (e) {
      throw SaveException('保存到下载目录失败：$e');
    }
  }

  @override
  Future<void> openPermissionSettings() async {
    await AppSettings.openAppSettings();
  }
}

/// 移动端：写系统相册。
class GallerySaveTarget implements SaveTarget {
  const GallerySaveTarget({this.album = 'ImgCat'});

  final String album;

  @override
  Future<String> save({required File tempFile, required String fileName, String? mimeType}) async {
    try {
      await Gal.putImage(tempFile.path, album: album);
      return '相册/$album';
    } on GalException catch (e) {
      throw SaveException(
        e.type == GalExceptionType.accessDenied ? '没有相册写入权限' : '保存到相册失败：${e.type.message}',
        needsPermission: e.type == GalExceptionType.accessDenied,
      );
    }
  }

  @override
  Future<void> openPermissionSettings() async {
    await AppSettings.openAppSettings(type: AppSettingsType.settings);
  }
}
