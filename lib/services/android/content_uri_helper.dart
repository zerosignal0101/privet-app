import 'dart:io' show Platform;

import 'package:flutter/services.dart';

const _channel = MethodChannel('privet/file');

/// Android SAF helpers over the `privet/file` channel. The daemon only reads
/// real filesystem paths, so any `content://` URI must be copied to the app
/// cache before it can be sent. The copies land under `<cache>/privet/send-cache/`
/// and are deleted per-transfer by `SendCache` (see `lib/services/android/`),
/// not by a blanket wipe.
Future<String?> cacheToPath(String contentUri) async {
  if (!Platform.isAndroid) return null;
  try {
    return await _channel.invokeMethod<String>('copyContentUri', {'uri': contentUri});
  } catch (_) {
    return null;
  }
}

/// Opens a `content://` URI with the system default handler.
Future<bool> openContentUri(String contentUri) async {
  if (!Platform.isAndroid) return false;
  try {
    return await _channel.invokeMethod<bool>('openContentUri', {'uri': contentUri}) ?? false;
  } catch (_) {
    return false;
  }
}

/// True when a `content://` URI is still readable (permission held).
Future<bool> checkContentUri(String contentUri) async {
  if (!Platform.isAndroid) return false;
  try {
    return await _channel.invokeMethod<bool>('checkContentUri', {'uri': contentUri}) ?? false;
  } catch (_) {
    return false;
  }
}
