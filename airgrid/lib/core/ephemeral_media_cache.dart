import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Temporary-file cache for ephemeral media.
class EphemeralMediaCache {
  static const String _cacheFolderName = 'airgrid_media_cache';

  Future<Directory> _ensureCacheDir() async {
    final tempDir = await getTemporaryDirectory();
    final cacheDir = Directory(p.join(tempDir.path, _cacheFolderName));
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir;
  }

  Future<String> writeMediaBytes(
    String transferId,
    Uint8List bytes, {
    required String extension,
    String? fileName,
  }) async {
    final dir = await _ensureCacheDir();
    final ext = extension.startsWith('.') ? extension : '.$extension';
    final safeFileName = fileName == null || fileName.isEmpty
        ? ''
        : '_${p.basename(fileName)}';
    final filePath = p.join(dir.path, '$transferId$safeFileName$ext');
    final file = File(filePath);
    await file.writeAsBytes(bytes, flush: true);
    return filePath;
  }

  Future<String> writeImageBytes(
    String transferId,
    Uint8List bytes, {
    String extension = 'jpg',
  }) {
    return writeMediaBytes(
      transferId,
      bytes,
      extension: extension,
    );
  }

  Future<String> writeAudioBytes(
    String transferId,
    Uint8List bytes, {
    String extension = 'm4a',
  }) {
    return writeMediaBytes(
      transferId,
      bytes,
      extension: extension,
    );
  }

  Future<String> writeFileBytes(
    String transferId,
    Uint8List bytes, {
    required String fileName,
  }) {
    final ext = p.extension(fileName).replaceFirst('.', '');
    return writeMediaBytes(
      transferId,
      bytes,
      extension: ext.isEmpty ? 'bin' : ext,
      fileName: fileName,
    );
  }

  Future<void> cleanup({int maxAgeHours = 24}) async {
    final dir = await _ensureCacheDir();
    final cutoff = DateTime.now().subtract(Duration(hours: maxAgeHours));
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entity.delete();
        }
      } catch (_) {
        // Best effort cleanup.
      }
    }
  }
}
