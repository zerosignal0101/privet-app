import 'package:flutter_riverpod/flutter_riverpod.dart';

/// An incoming `ACTION_SEND` payload: real cached file paths (already copied
/// to the send-cache by the native side) and/or plain text. Held until the UI
/// is ready to show the send preparation page — share intents can arrive
/// before the first frame on cold start.
class PendingShareData {
  const PendingShareData({this.paths = const [], this.uris = const [], this.text});
  final List<String> paths;

  /// The original `content://` references the cached [paths] were copied from,
  /// positionally aligned with [paths]. May be shorter than [paths] (or empty,
  /// on an older native build) when a URI wasn't recoverable; pair defensively.
  final List<String> uris;
  final String? text;

  /// Parses the `{paths, uris, text}` map pushed/pulled on the `privet/share`
  /// channel.
  factory PendingShareData.fromArgs(Object? args) {
    if (args is! Map) return const PendingShareData();
    final paths = (args['paths'] as List?)
            ?.whereType<String>()
            .toList() ??
        const <String>[];
    final uris = (args['uris'] as List?)?.whereType<String>().toList() ??
        const <String>[];
    return PendingShareData(
        paths: paths, uris: uris, text: args['text'] as String?);
  }

  bool get isEmpty =>
      paths.isEmpty && (text == null || text!.trim().isEmpty);
}

final pendingShareProvider = NotifierProvider<PendingShareNotifier, PendingShareData?>(
    PendingShareNotifier.new);

class PendingShareNotifier extends Notifier<PendingShareData?> {
  @override
  PendingShareData? build() => null;

  void set(PendingShareData data) => state = data;
  void clear() => state = null;
}
