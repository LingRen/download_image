import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:download_image/core/bridge/bridge_protocol.dart';
import 'package:download_image/features/download/blob_file_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('imgcat_test'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  BlobChunk chunk(String id, int seq, List<int> bytes, {bool last = false}) {
    return BlobChunk(id: id, seq: seq, data: base64Encode(bytes), last: last);
  }

  test('按序写入所有分块，内容与原始字节一致', () async {
    final file = File('${tempDir.path}/out.bin');
    final writer = BlobFileWriter(file);
    await writer.open();

    await writer.add(chunk('dl-1', 0, Uint8List.fromList(List.filled(3, 1))));
    expect(writer.receivedBytes, 3);
    expect(writer.isComplete, isFalse);

    await writer.add(
      chunk('dl-1', 1, Uint8List.fromList(List.filled(2, 2)), last: true),
    );
    await writer.close();

    expect(writer.receivedBytes, 5);
    expect(writer.isComplete, isTrue);
    expect(await file.length(), 5);
    expect(await file.readAsBytes(), [1, 1, 1, 2, 2]);
  });

  test('空分块（0 字节图片）也能正常完成', () async {
    final file = File('${tempDir.path}/empty.bin');
    final writer = BlobFileWriter(file);
    await writer.open();
    await writer.add(chunk('dl-1', 0, const [], last: true));
    await writer.close();
    expect(writer.isComplete, isTrue);
    expect(await file.length(), 0);
  });

  test('分块乱序抛 StateError', () async {
    final file = File('${tempDir.path}/bad.bin');
    final writer = BlobFileWriter(file);
    await writer.open();
    expect(
      () => writer.add(chunk('dl-1', 1, const [1])),
      throwsA(isA<StateError>()),
    );
    await writer.close();
  });

  test('未打开或已关闭时 add 抛可辨认的 StateError', () async {
    final file = File('${tempDir.path}/lifecycle.bin');
    final writer = BlobFileWriter(file);
    expect(
      () => writer.add(chunk('dl-1', 0, const [1])),
      throwsA(isA<StateError>()),
      reason: 'open 之前不接受分块',
    );
    await writer.open();
    await writer.close();
    expect(
      () => writer.add(chunk('dl-1', 0, const [1])),
      throwsA(isA<StateError>()),
      reason: 'close 之后不接受分块',
    );
  });

  test('超过 512KB 的大文件分块写入后大小正确', () async {
    final file = File('${tempDir.path}/big.bin');
    final writer = BlobFileWriter(file);
    await writer.open();
    final block = Uint8List(kBlobChunkBytes);
    await writer.add(chunk('dl-1', 0, block));
    await writer.add(chunk('dl-1', 1, Uint8List(1000), last: true));
    await writer.close();
    expect(await file.length(), kBlobChunkBytes + 1000);
  });
}
