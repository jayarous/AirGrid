import 'dart:convert';
import 'dart:typed_data';

/// Versioned envelope carried in packet content for private image messages.
class ImageAttachmentPayload {
  static const int currentVersion = 1;

  final int version;
  final String transferId;
  final String mimeType;
  final int byteLength;
  final int? width;
  final int? height;
  final String dataBase64;
  final String? localTempPath;

  const ImageAttachmentPayload({
    this.version = currentVersion,
    required this.transferId,
    required this.mimeType,
    required this.byteLength,
    required this.dataBase64,
    this.width,
    this.height,
    this.localTempPath,
  });

  Uint8List get bytes => base64Decode(dataBase64);

  Map<String, dynamic> toJson() => {
    'v': version,
    'kind': 'image',
    'transferId': transferId,
    'mimeType': mimeType,
    'byteLength': byteLength,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    'data': dataBase64,
  };

  String toWire() => jsonEncode(toJson());

  static ImageAttachmentPayload? fromWire(String wire) {
    try {
      final json = jsonDecode(wire);
      if (json is! Map<String, dynamic>) return null;
      if (json['kind'] != 'image') return null;
      final dataBase64 = json['data'] as String?;
      final transferId = json['transferId'] as String?;
      final mimeType = json['mimeType'] as String?;
      final byteLength = json['byteLength'] as int?;
      if (dataBase64 == null ||
          transferId == null ||
          mimeType == null ||
          byteLength == null) {
        return null;
      }

      return ImageAttachmentPayload(
        version: json['v'] as int? ?? currentVersion,
        transferId: transferId,
        mimeType: mimeType,
        byteLength: byteLength,
        width: json['width'] as int?,
        height: json['height'] as int?,
        dataBase64: dataBase64,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Versioned envelope carried in packet content for private voice-note messages.
class AudioAttachmentPayload {
  static const int currentVersion = 1;

  final int version;
  final String transferId;
  final String mimeType;
  final int byteLength;
  final int? durationMs;
  final String dataBase64;
  final String? localTempPath;

  const AudioAttachmentPayload({
    this.version = currentVersion,
    required this.transferId,
    required this.mimeType,
    required this.byteLength,
    required this.dataBase64,
    this.durationMs,
    this.localTempPath,
  });

  Uint8List get bytes => base64Decode(dataBase64);

  Map<String, dynamic> toJson() => {
    'v': version,
    'kind': 'audio',
    'transferId': transferId,
    'mimeType': mimeType,
    'byteLength': byteLength,
    if (durationMs != null) 'durationMs': durationMs,
    'data': dataBase64,
  };

  String toWire() => jsonEncode(toJson());

  static AudioAttachmentPayload? fromWire(String wire) {
    try {
      final json = jsonDecode(wire);
      if (json is! Map<String, dynamic>) return null;
      if (json['kind'] != 'audio') return null;
      final dataBase64 = json['data'] as String?;
      final transferId = json['transferId'] as String?;
      final mimeType = json['mimeType'] as String?;
      final byteLength = json['byteLength'] as int?;
      if (dataBase64 == null ||
          transferId == null ||
          mimeType == null ||
          byteLength == null) {
        return null;
      }

      return AudioAttachmentPayload(
        version: json['v'] as int? ?? currentVersion,
        transferId: transferId,
        mimeType: mimeType,
        byteLength: byteLength,
        durationMs: json['durationMs'] as int?,
        dataBase64: dataBase64,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Versioned envelope carried in packet content for private file messages.
class FileAttachmentPayload {
  static const int currentVersion = 1;

  final int version;
  final String transferId;
  final String fileName;
  final String mimeType;
  final int byteLength;
  final String dataBase64;
  final String? localTempPath;

  const FileAttachmentPayload({
    this.version = currentVersion,
    required this.transferId,
    required this.fileName,
    required this.mimeType,
    required this.byteLength,
    required this.dataBase64,
    this.localTempPath,
  });

  Uint8List get bytes => base64Decode(dataBase64);

  Map<String, dynamic> toJson() => {
    'v': version,
    'kind': 'file',
    'transferId': transferId,
    'fileName': fileName,
    'mimeType': mimeType,
    'byteLength': byteLength,
    'data': dataBase64,
  };

  String toWire() => jsonEncode(toJson());

  static FileAttachmentPayload? fromWire(String wire) {
    try {
      final json = jsonDecode(wire);
      if (json is! Map<String, dynamic>) return null;
      if (json['kind'] != 'file') return null;
      final dataBase64 = json['data'] as String?;
      final transferId = json['transferId'] as String?;
      final fileName = json['fileName'] as String?;
      final mimeType = json['mimeType'] as String?;
      final byteLength = json['byteLength'] as int?;
      if (dataBase64 == null ||
          transferId == null ||
          fileName == null ||
          mimeType == null ||
          byteLength == null) {
        return null;
      }

      return FileAttachmentPayload(
        version: json['v'] as int? ?? currentVersion,
        transferId: transferId,
        fileName: fileName,
        mimeType: mimeType,
        byteLength: byteLength,
        dataBase64: dataBase64,
      );
    } catch (_) {
      return null;
    }
  }
}
