import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Picks a directory on Android via SAF (`ACTION_OPEN_DOCUMENT_TREE`) and
/// returns the top-level cached directory path.
///
/// The native side copies the tree to `<cache>/privet/send-cache/<session>/`
/// preserving relative paths, and returns `<session>/<folderName>` — the path
/// the send flow hands verbatim to the daemon, which recurses it itself (so the
/// directory hierarchy survives on the receiving side).
class ContentUriDirectoryHelper {
  static const _channel = MethodChannel('privet/file');

  /// Returns the cached root directory path, or null when the user cancels,
  /// the picker is unavailable, or copying fails.
  static Future<String?> pickAndCacheDirectory() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('pickDirectory');
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('[SAF] pickDirectory error: $e');
      return null;
    }
  }
}
