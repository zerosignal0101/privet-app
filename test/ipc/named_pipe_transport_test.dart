import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/services/ipc/named_pipe_transport.dart';

void main() {
  test('connect fails cleanly when the pipe does not exist', () async {
    if (!Platform.isWindows) return; // win32-specific
    final transport = NamedPipeTransport(r'\\.\pipe\privet-app-test-absent');
    await expectLater(
      transport.connect(),
      throwsA(isA<NamedPipeConnectException>()),
    );
  });
}
