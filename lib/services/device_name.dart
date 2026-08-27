import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel;

const MethodChannel _platform = MethodChannel('privet/platform');

/// Platform default device name for the daemon config: the host name on
/// desktop, the device model on Android (where `Platform.localHostname` returns
/// "localhost"). Mirrors the legacy privet app's resolution (privet-old), which
/// queries a native channel on Android for `$manufacturer $model`.
Future<String> resolveDefaultDeviceName({
  bool? isAndroid,
  String Function()? hostname,
}) async {
  final onAndroid = isAndroid ?? Platform.isAndroid;
  final resolveHostname = hostname ?? () => Platform.localHostname;
  if (onAndroid) {
    try {
      final name = await _platform.invokeMethod<String>('getDeviceName');
      if (name != null && name.isNotEmpty) return name;
    } catch (_) {
      // Channel unavailable — fall through to the host name.
    }
  }
  try {
    return resolveHostname();
  } catch (_) {
    return 'privet-device';
  }
}

/// Per-user config directory for the desktop daemon, e.g.
/// `%LOCALAPPDATA%\privet\config.json` on Windows and
/// `$XDG_CONFIG_HOME/privet/config.json` on POSIX. Returns null when no
/// user-config dir is discoverable.
String? desktopConfigPath() {
  final base = Platform.isWindows
      ? (Platform.environment['LOCALAPPDATA'] ??
            Platform.environment['APPDATA'])
      : (Platform.environment['XDG_CONFIG_HOME'] ??
            (Platform.environment['HOME']?.isNotEmpty == true
                ? '${Platform.environment['HOME']}/.config'
                : null));
  if (base == null || base.isEmpty) return null;
  return '$base${Platform.pathSeparator}privet${Platform.pathSeparator}config.json';
}

/// Writes a minimal daemon config with just `device_name` (the host name) so
/// the desktop daemon announces the host instead of the hardcoded default; the
/// daemon fills every other field from its own defaults (`#[serde(default)]`).
/// Returns the config path, or null on Android / when the name or path is
/// unavailable. [path] is injectable for tests.
String? writeDesktopDeviceNameConfig({String? path}) {
  if (Platform.isAndroid) return null;
  final target = path ?? desktopConfigPath();
  if (target == null) return null;
  String host;
  try {
    host = Platform.localHostname;
  } catch (_) {
    return null;
  }
  if (host.isEmpty) return null;
  try {
    final file = File(target);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode({'device_name': host}), flush: true);
    return target;
  } catch (_) {
    return null;
  }
}
