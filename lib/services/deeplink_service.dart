import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pairing_url.dart';

/// UI-layer provider for the single [DeeplinkService] instance.
final deeplinkServiceProvider = Provider<DeeplinkService>((ref) {
  final service = DeeplinkService();
  ref.onDispose(service.dispose);
  return service;
});

/// Listens for incoming pairing URLs (`privet://pair?...` via the `privet`
/// protocol handler on desktop / intent-filter on Android) and exposes parsed
/// URLs on a broadcast stream. The `privet` scheme is registered by
/// `app_links` at build time on Windows; the Android manifest intent-filter is
/// wired in Plan 4.
class DeeplinkService {
  DeeplinkService({AppLinks? appLinks}) : _appLinks = appLinks ?? AppLinks();

  final AppLinks _appLinks;
  final _controller = StreamController<ParsedPairingUrl>.broadcast();
  StreamSubscription<Uri>? _sub;

  /// Stream of parsed pairing URLs.
  Stream<ParsedPairingUrl> get pairingUrls => _controller.stream;

  /// Start listening. Handles the cold-start link and then live links.
  Future<void> start() async {
    if (_sub != null) return;
    _sub = _appLinks.uriLinkStream.listen((uri) => handleUrl(uri.toString()));
    final initial = await _appLinks.getInitialLink();
    if (initial != null) handleUrl(initial.toString());
  }

  /// Capture a pairing URL string and parse it. Returns the parsed URL if
  /// valid, null otherwise.
  ParsedPairingUrl? handleUrl(String url) {
    final parsed = PairingUrl.parse(url);
    if (parsed != null) _controller.add(parsed);
    return parsed;
  }

  void dispose() {
    _sub?.cancel();
    _controller.close();
  }
}
