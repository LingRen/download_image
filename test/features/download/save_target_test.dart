import 'dart:io';

import 'package:download_image/features/download/save_target.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late Directory downloadsDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('imgcat_save');
    downloadsDir = Directory('${tempDir.path}/Downloads')..createSync(recursive: true);
  });
  tearDown(() => tempDir.deleteSync(recursive: true));

  test('下载目录写入：文件落到目标目录且内容一致', () async {
    final temp = File('${tempDir.path}/tmp.jpg')..writeAsBytesSync([1, 2, 3]);
    final target = DownloadsSaveTarget(downloadsDirectory: () async => downloadsDir);

    final savedPath = await target.save(tempFile: temp, fileName: 'pic.jpg', mimeType: 'image/jpeg');

    expect(savedPath, '${downloadsDir.path}/pic.jpg');
    expect(File(savedPath).readAsBytesSync(), [1, 2, 3]);
  });

  test('重名时自动追加序号，不覆盖已有文件', () async {
    File('${downloadsDir.path}/pic.jpg').writeAsBytesSync([9]);
    final temp = File('${tempDir.path}/tmp.jpg')..writeAsBytesSync([1]);
    final target = DownloadsSaveTarget(downloadsDirectory: () async => downloadsDir);

    final savedPath = await target.save(tempFile: temp, fileName: 'pic.jpg');

    expect(savedPath, '${downloadsDir.path}/pic (1).jpg');
    expect(File('${downloadsDir.path}/pic.jpg').readAsBytesSync(), [9]);
  });

  test('目标目录不存在时自动创建', () async {
    final nested = Directory('${tempDir.path}/none/here');
    final temp = File('${tempDir.path}/tmp.jpg')..writeAsBytesSync([1]);
    final target = DownloadsSaveTarget(downloadsDirectory: () async => nested);

    final savedPath = await target.save(tempFile: temp, fileName: 'a.jpg');

    expect(Directory('${tempDir.path}/none/here').existsSync(), isTrue);
    expect(File(savedPath).existsSync(), isTrue);
  });

  test('resolveFileName 在无冲突时返回原名', () {
    expect(resolveFileName('i.jpg', (name) => false), 'i.jpg');
    expect(resolveFileName('i.jpg', (name) => name == 'i.jpg'), 'i (1).jpg');
    expect(resolveFileName('i.jpg', (name) => name != 'i (5).jpg'), 'i (5).jpg');
  });
}