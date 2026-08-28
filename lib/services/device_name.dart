import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:shared_preferences/shared_preferences.dart';

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

/// The persisted "App Device Name" pref from SharedPreferences, or null when
/// the user has not set one. The Settings page and the daemon config both use
/// this so a user-chosen name survives restarts and is what the daemon
/// announces.
Future<String?> savedDeviceNamePref() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString('device_name');
    return (value != null && value.isNotEmpty) ? value : null;
  } catch (_) {
    return null;
  }
}

/// The device name to put in the daemon config: the user's persisted "App
/// Device Name" when set, otherwise the platform default (host / device model).
Future<String> resolveConfiguredDeviceName() async =>
    (await savedDeviceNamePref()) ?? await resolveDefaultDeviceName();

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

/// Writes the daemon config's `device_name` (the persisted "App Device Name"
/// pref when set, else the host name) so the desktop daemon announces the
/// configured name instead of the hardcoded default. Merges into any existing
/// config file so fields the daemon already persisted (`save_dir`,
/// `accept_all_trusted`, `collision_policy`) survive — writing a fresh object
/// here would reset them on the next launch. Returns the config path, or null
/// on Android / when the name or path is unavailable. [path] is injectable for
/// tests.
Future<String?> writeDesktopDeviceNameConfig({String? path}) async {
  if (Platform.isAndroid) return null;
  final target = path ?? desktopConfigPath();
  if (target == null) return null;
  final name = await resolveConfiguredDeviceName();
  if (name.isEmpty) return null;
  try {
    final file = File(target);
    file.parent.createSync(recursive: true);
    final Map<String, dynamic> existing = file.existsSync()
        ? (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)
        : <String, dynamic>{};
    existing['device_name'] = name;
    file.writeAsStringSync(jsonEncode(existing), flush: true);
    return target;
  } catch (_) {
    return null;
  }
}
