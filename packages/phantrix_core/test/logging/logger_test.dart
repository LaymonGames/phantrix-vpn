import 'package:phantrix_core/src/logging/logger.dart';
import 'package:test/test.dart';

/// The logger's contract is that a sink never receives a secret. Redacting
/// only the structured fields left the message as a bypass: a caller that
/// interpolated a value into the text sent it out verbatim. These tests pin
/// that the message is redacted too, both in the buffer and at the sink.
void main() {
  group('Logger redaction', () {
    test('redacts a secret interpolated into the message', () {
      final logger = Logger(tag: 'test', bufferSize: 8);
      logger.info('using key 02R31BtVMJe/5r8cMd8uRVf6DysDrWKFXxDlMdRDU6c=');

      final message = logger.buffer.single.message;
      expect(message, isNot(contains('02R31BtVMJe')));
      expect(message, contains('[redacted'));
    });

    test('an external sink receives the redacted message, not the raw one', () {
      final records = <LogRecord>[];
      final previous = Logger.external;
      Logger.external = records.add;
      addTearDown(() => Logger.external = previous);

      Logger(tag: 'test').error('password=hunter2');

      expect(records.single.message, isNot(contains('hunter2')));
      expect(records.single.message, contains('[redacted'));
    });
  });
}
