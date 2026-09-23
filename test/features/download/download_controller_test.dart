import 'package:download_image/core/bridge/bridge_protocol.dart';
import 'package:download_image/core/model/image_asset.dart';
import 'package:download_image/features/download/download_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_download.dart';

ImageAsset _asset(String url) => ImageAsset(url: url, width: 100, height: 100);

void main() {
  test('串行下载全部成功，状态与位置写回', () async {
    final executor = FakeDownloadExecutor();
    final controller = DownloadController(
      executor: executor,
      blobSink: FakeBlobSink(),
    );

    await controller.downloadAll([
      _asset('https://a.com/1.jpg'),
      _asset('https://a.com/2.jpg'),
    ]);

    expect(executor.calls, ['https://a.com/1.jpg', 'https://a.com/2.jpg']);
    expect(controller.statusOf('https://a.com/1.jpg'), DownloadStatus.done);
    expect(controller.locationOf('https://a.com/2.jpg'), '/Downloads/x.jpg');
    expect(controller.isBusy, isFalse);
    expect(controller.completed, 2);
    expect(controller.failedUrls, isEmpty);
  });

  test('单项失败不中断其他项，并记录失败与错误文案', () async {
    final executor = FakeDownloadExecutor(
      failingUrls: {'https://a.com/bad.jpg'},
    );
    final controller = DownloadController(
      executor: executor,
      blobSink: FakeBlobSink(),
    );

    await controller.downloadAll([
      _asset('https://a.com/bad.jpg'),
      _asset('https://a.com/ok.jpg'),
    ]);

    expect(controller.statusOf('https://a.com/bad.jpg'), DownloadStatus.failed);
    expect(controller.errorOf('https://a.com/bad.jpg'), '镜像 403');
    expect(controller.statusOf('https://a.com/ok.jpg'), DownloadStatus.done);
    expect(controller.failedUrls, ['https://a.com/bad.jpg']);
  });

  test('权限被拒时置 needsPermission，重试成功后清除', () async {
    final executor = FakeDownloadExecutor(
      permissionUrls: {'https://a.com/p.jpg'},
    );
    final controller = DownloadController(
      executor: executor,
      blobSink: FakeBlobSink(),
    );

    await controller.downloadAll([_asset('https://a.com/p.jpg')]);
    expect(controller.needsPermission, isTrue);

    executor.permissionUrls.clear();
    await controller.retry(_asset('https://a.com/p.jpg'));
    expect(controller.statusOf('https://a.com/p.jpg'), DownloadStatus.done);
    expect(controller.needsPermission, isFalse);
  });

  test('忙碌中重复调用直接返回，不重复入队', () async {
    final executor = FakeDownloadExecutor();
    final controller = DownloadController(
      executor: executor,
      blobSink: FakeBlobSink(),
    );

    final first = controller.downloadAll([_asset('https://a.com/1.jpg')]);
    final second = controller.downloadAll([_asset('https://a.com/2.jpg')]);
    await Future.wait([first, second]);

    expect(executor.calls, ['https://a.com/1.jpg']);
  });

  test('blob 分块转发给 sink', () async {
    final sink = FakeBlobSink();
    final controller = DownloadController(
      executor: FakeDownloadExecutor(),
      blobSink: sink,
    );

    await controller.acceptBlobChunk(
      const BlobChunk(id: 'dl-1', seq: 0, data: '', last: true),
    );

    expect(sink.chunks.length, 1);
    expect(sink.chunks.single.id, 'dl-1');
  });

  test('openPermissionSettings 透传到执行器', () async {
    final executor = FakeDownloadExecutor();
    final controller = DownloadController(
      executor: executor,
      blobSink: FakeBlobSink(),
    );

    await controller.openPermissionSettings();

    expect(executor.permissionSettingsOpened, isTrue);
  });
}
