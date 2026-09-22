import 'dart:convert';
import 'dart:io';

import '../../core/bridge/bridge_protocol.dart';

/// 把 JS 回传的 base64 分块边收边写入临时文件，避免大图整体驻留内存。
class BlobFileWriter {
  BlobFileWriter(this.file);

  final File file;

  RandomAccessFile? _raf;
  int _expectedSeq = 0;
  int _receivedBytes = 0;
  bool _complete = false;

  /// 已接收字节数。
  int get receivedBytes => _receivedBytes;

  /// 收到 last 分块后为 true。
  bool get isComplete => _complete;

  Future<void> open() async {
    await file.parent.create(recursive: true);
    _raf = await file.open(mode: FileMode.writeOnly);
  }

  Future<void> add(BlobChunk chunk) async {
    if (chunk.seq != _expectedSeq) {
      throw StateError('分块乱序：期望 $_expectedSeq，收到 ${chunk.seq}');
    }
    final bytes = base64Decode(chunk.data);
    await _raf!.writeFrom(bytes);
    _receivedBytes += bytes.length;
    _expectedSeq++;
    if (chunk.last) _complete = true;
  }

  Future<void> close() async {
    await _raf?.close();
    _raf = null;
  }
}