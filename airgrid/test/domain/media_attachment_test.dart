import 'package:airgrid/domain/models/media_attachment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AudioAttachmentPayload', () {
    test('round-trips walkie source across wire format', () {
      const payload = AudioAttachmentPayload(
        transferId: 'tx-1',
        mimeType: 'audio/m4a',
        byteLength: 3,
        durationMs: 1200,
        source: AudioAttachmentPayload.sourceWalkie,
        dataBase64: 'AQID',
      );

      final decoded = AudioAttachmentPayload.fromWire(payload.toWire());

      expect(decoded, isNotNull);
      expect(decoded!.source, AudioAttachmentPayload.sourceWalkie);
      expect(decoded.durationMs, 1200);
      expect(decoded.transferId, 'tx-1');
    });

    test('parses payload without source for backward compatibility', () {
      const wire =
          '{"v":1,"kind":"audio","transferId":"tx-legacy","mimeType":"audio/m4a","byteLength":3,"durationMs":900,"data":"AQID"}';

      final decoded = AudioAttachmentPayload.fromWire(wire);

      expect(decoded, isNotNull);
      expect(decoded!.source, isNull);
      expect(decoded.transferId, 'tx-legacy');
      expect(decoded.durationMs, 900);
    });
  });
}
