import 'dart:io';

import 'package:archive/archive_io.dart';

/// 压缩包里的一个条目：源文件 + 包内路径。
class ZipEntry {
  const ZipEntry({required this.file, required this.name});

  final File file;
  final String name;
}

/// 把若干本地文件打成一个 zip。
///
/// 用 [ZipFileEncoder] 流式写盘，逐条从磁盘读取，不会把整批图片读进内存，
/// 因此大图批量打包也不会撑爆内存。包内条目名由调用方负责去重。
class ZipPackager {
  const ZipPackager();

  Future<File> pack({
    required File destination,
    required List<ZipEntry> entries,
  }) async {
    final encoder = ZipFileEncoder();
    encoder.create(destination.path);
    try {
      for (final entry in entries) {
        await encoder.addFile(entry.file, entry.name);
      }
    } finally {
      // 即使中途失败也要关闭输出流，避免句柄泄漏；失败产物由调用方清理。
      await encoder.close();
    }
    return destination;
  }
}
