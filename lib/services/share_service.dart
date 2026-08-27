import 'dart:async';

import 'package:flutter/services.dart';

import '../providers/pending_share.dart';

/// Receives ACTION_SEND payloads from the native `privet/share` channel.
///
/// Two delivery paths:
///   - `onShare` push — app already running when the share intent lands
///     (MainActivity.onNewIntent).
///   - `getPendingShare` pull — cold start; the native side stashed the args
///     before the Dart engine was ready.
class ShareService {
  static const MethodChannel _channel = MethodChannel('privet/share');

  final _shares = StreamController<PendingShareData>.broadcast();
  Stream<PendingShareData> get shares => _shares.stream;

  Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onShare') {
        final data = PendingShareData.fromArgs(call.arguments);
        if (!data.isEmpty) _shares.add(data);
      }
      return null;
    });
    await pull();
  }

  /// Pull any pending share the native side is holding (cold start / resume).
  Future<void> pull() async {
    try {
      final args = await _channel.invokeMethod<dynamic>('getPendingShare');
      final data = PendingShareData.fromArgs(args);
      if (!data.isEmpty) _shares.add(data);
    } catch (_) {
      // Channel not available on this platform.
    }
  }

  void dispose() {
    _shares.close();
  }
}
