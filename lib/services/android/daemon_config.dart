import 'dart:convert';

import 'package:flutter/services.dart';

const MethodChannel _platform = MethodChannel('privet/platform');

/// Resolves the device CPU ABI (`arm64-v8a` / `armeabi-v7a` / `x86_64`) from
/// the `privet/platform` channel. Falls back to `arm64-v8a` when unavailable
/// (e.g. host-side tests, plugin missing).
Future<String> androidAbi() async {
  try {
    return await _platform.invokeMethod<String>('getAbi') ?? 'arm64-v8a';
  } catch (_) {
    return 'arm64-v8a';
  }
}

/// Strict JSON for the on-device daemon config.
///
/// Ports use the real defaults (privet_protocol::constants), NOT 0: a 0
/// discovery port makes the UDP beacon announce to `255.255.255.255:0` (dead)
/// and a 0 QUIC/TCP port advertises unreachable endpoints to peers. `0` is only
/// correct for the desktop smoke test, which never enables discovery.
/// Discovery (UDP) is 47809, distinct from QUIC (UDP 47808): binding both on
/// 47808 makes the engine fail with "Address already in use" on startup.
String encodeDaemonConfig({
  required String deviceName,
  required String dataDir,
  required String saveDir,
  required String socketPath,
}) {
  return jsonEncode({
    'device_name': deviceName,
    'data_dir': dataDir,
    'save_dir': saveDir,
    'ipc_endpoint': socketPath,
    'quic_port': 47808,
    'tcp_port': 47808,
    'discovery_port': 47809,
  });
}
