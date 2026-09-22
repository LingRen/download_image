import 'package:download_image/core/bridge/bridge_protocol.dart';
import 'package:download_image/core/model/image_asset.dart';
import 'package:download_image/features/download/download_controller.dart';
import 'package:download_image/features/download/download_service.dart';
import 'package:download_image/features/download/save_target.dart';
import 'package:download_image/features/download/webview_blob_fetcher.dart';

/// 可控的假下载执行器：按 URL 决定成功或抛错。
class FakeDownloadExecutor implements DownloadExecutor {
  FakeDownloadExecutor({
    Set<String>? failingUrls,
    Set<String>? permissionUrls,
  })  : failingUrls = failingUrls ?? <String>{},
        permissionUrls = permissionUrls ?? <String>{};

  final Set<String> failingUrls;
  final Set<String> permissionUrls;
  final List<String> calls = <String>[];
  bool permissionSettingsOpened = false;

  @override
  Future<DownloadOutcome> download(ImageAsset asset) async {
    calls.add(asset.url);
    if (permissionUrls.contains(asset.url)) {
      throw SaveException('没有相册写入权限', needsPermission: true);
    }
    if (failingUrls.contains(asset.url)) {
      throw SaveException('镜像 403');
    }
    return DownloadOutcome(location: '/Downloads/x.jpg', usedFallback: false, bytes: 3);
  }

  @override
  Future<void> openPermissionSettings() async {
    permissionSettingsOpened = true;
  }
}

/// 什么都不做的 blob 接收器。
class FakeBlobSink implements BlobChunkSink {
  final List<BlobChunk> chunks = <BlobChunk>[];

  @override
  Future<void> accept(BlobChunk chunk) async {
    chunks.add(chunk);
  }
}

/// 给 widget 测试用的下载控制器。
DownloadController fakeDownloadController({FakeDownloadExecutor? executor}) {
  return DownloadController(
    executor: executor ?? FakeDownloadExecutor(),
    blobSink: FakeBlobSink(),
  );
}