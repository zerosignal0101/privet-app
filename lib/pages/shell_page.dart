import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../providers/peers.dart';
import '../providers/pending_share.dart';
import '../providers/send_preparation.dart';
import '../services/clipboard_service.dart';
import '../services/deeplink_service.dart';
import '../services/pairing_url.dart';
import '../services/privet_service.dart';
import '../services/share_service.dart';
import '../state/daemon_state.dart';
import 'history_page.dart';
import 'home_page.dart';
import 'send_preparation_page.dart';
import 'settings_page.dart';

final shellTabProvider =
    NotifierProvider<ShellTabNotifier, int>(ShellTabNotifier.new);

class ShellTabNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void select(int index) => state = index;
}

/// Bottom navigation shell with 3 tabs: Home, History, Settings. Also owns the
/// deeplink listener: a scanned `privet://pair` URL pairs this device with the
/// remote (matching by fingerprint, or by endpoint as a fallback).
class ShellPage extends ConsumerStatefulWidget {
  const ShellPage({super.key});

  @override
  ConsumerState<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends ConsumerState<ShellPage> {
  StreamSubscription<ParsedPairingUrl>? _deeplinkSub;
  StreamSubscription<PendingShareData>? _shareSub;
  ShareService? _shareService;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final service = ref.read(deeplinkServiceProvider);
      _deeplinkSub = service.pairingUrls.listen(_handlePairingUrl);
      service.start();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final share = ShareService();
      _shareService = share;
      _shareSub = share.shares.listen(_handleShareData);
      share.start();
    });
  }

  @override
  void dispose() {
    _deeplinkSub?.cancel();
    _shareSub?.cancel();
    _shareService?.dispose();
    super.dispose();
  }

  /// Turns an incoming share into the send preparation page. File paths are
  /// already cached by the native side; shared text is written to a temp file.
  Future<void> _handleShareData(PendingShareData data) async {
    final entries = <SendFileEntry>[];
    for (final path in data.paths) {
      final file = File(path);
      if (file.existsSync()) {
        entries.add(SendFileEntry(
          path: path,
          relativePath: path.split(RegExp(r'[/\\]')).last,
          size: file.lengthSync(),
        ));
      }
    }
    final text = data.text;
    if (text != null && text.trim().isNotEmpty) {
      try {
        final dir = (await getTemporaryDirectory()).path;
        final name = ClipboardService.textFilename(text);
        final (path: txtPath, relativePath: relPath) =
            ClipboardService.uniqueFile(dir, '$name.txt');
        await File(txtPath).writeAsString(text);
        entries.add(SendFileEntry(
          path: txtPath,
          relativePath: relPath,
          size: File(txtPath).lengthSync(),
        ));
      } catch (e) {
        debugPrint('[share] failed to save shared text: $e');
      }
    }
    if (entries.isEmpty || !mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SendPreparationPage(initialEntries: entries),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(shellTabProvider);
    return Scaffold(
      body: IndexedStack(
        index: index,
        children: const [HomePage(), HistoryPage(), SettingsPage()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) =>
            ref.read(shellTabProvider.notifier).select(i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  Future<void> _handlePairingUrl(ParsedPairingUrl url) async {
    final service = ref.read(daemonStateProvider).service;
    if (service == null) return;
    try {
      final paired = await _pairWith(url, service);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(paired
            ? 'Paired with ${url.deviceName.isNotEmpty ? url.deviceName : 'device'}'
            : 'Pairing failed'),
      ));
      if (paired) ref.invalidate(trustedListProvider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Pairing failed: $e')));
    }
  }

  /// Pair using the URL's fingerprint (matched against discovered peers), or
  /// fall back to endpoint pairing when the peer has not been discovered yet.
  Future<bool> _pairWith(ParsedPairingUrl url, PrivetService service) async {
    final code = url.code ?? '';
    final matched = ref
        .read(peerListProvider)
        .where((p) => p.deviceFingerprint == url.fingerprint)
        .isNotEmpty;
    if (matched) {
      return (await service.pair(fingerprint: url.fingerprint, code: code))
          .paired;
    }
    if (url.hosts.isNotEmpty) {
      final host = url.hosts.first;
      final colon = host.lastIndexOf(':');
      final ip = colon >= 0 ? host.substring(0, colon) : host;
      final port =
          colon >= 0 ? int.tryParse(host.substring(colon + 1)) ?? 47808 : 47808;
      return (await service.pair(
              ip: ip, quicPort: port, tcpPort: port, code: code))
          .paired;
    }
    return false;
  }
}
