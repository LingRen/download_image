import 'dart:io';

import 'package:archive/archive.dart';
import 'package:download_image/features/download/zip_packager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zip_packager');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('按给定条目名打包，解出后名字与内容都对得上', () async {
    final first = File('${dir.path}/first.tmp')
      ..writeAsBytesSync(const [1, 2, 3]);
    final second = File('${dir.path}/second.tmp')..writeAsBytesSync([9]);
    final zip = File('${dir.path}/out.zip');

    await const ZipPackager().pack(
      destination: zip,
      entries: [
        ZipEntry(file: first, name: 'p.jpg'),
        ZipEntry(file: second, name: 'q (1).png'),
      ],
    );

    expect(await zip.exists(), isTrue);
    final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
    expect(archive.files.map((file) => file.name), ['p.jpg', 'q (1).png']);
    expect(archive.findFile('p.jpg')!.content, const [1, 2, 3]);
    expect(archive.findFile('q (1).png')!.content, [9]);
  });

  test('目标路径不可写时抛原始系统错误，不被 close 掩盖', () async {
    // 拿一个普通文件当父路径，让 OutputFileStream 开句柄时必然失败。
    final blocker = File('${dir.path}/blocker')..writeAsBytesSync(const [1]);
    final source = File('${dir.path}/a.tmp')..writeAsBytesSync(const [2]);

    // create() 必须留在 try 之外：ZipFileEncoder 的 _encoder/_output 是 late 字段，
    // 开句柄失败时不会被赋值，此时 close() 会抛 LateInitializationError 顶掉真实原因。
    await expectLater(
      const ZipPackager().pack(
        destination: File('${blocker.path}/out.zip'),
        entries: [ZipEntry(file: source, name: 'a.jpg')],
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('取图环节失败时仍然关闭输出流，错误照常抛出', () async {
    final zip = File('${dir.path}/out.zip');
    final missing = File('${dir.path}/gone.tmp');

    await expectLater(
      const ZipPackager().pack(
        destination: zip,
        entries: [ZipEntry(file: missing, name: 'gone.jpg')],
      ),
      throwsA(isA<FileSystemException>()),
    );

    // finally 里 close() 走完 endEncode，句柄已释放：能改名说明没有残留占用。
    await zip.rename('${dir.path}/renamed.zip');
  });
}
