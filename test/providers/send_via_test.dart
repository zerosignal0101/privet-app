// The `via` field lets a user pin a send to a specific IP of a trusted device —
// the way out of a network where discovery cannot work (AP client isolation).
//
// What these tests pin down is the contract with the engine, which is narrow:
//
//   * the address arrives as a **bare IP** (port stripped), because the engine
//     takes the port from the device record and refuses a ported `via`;
//   * omitting it leaves `via` out of the request entirely, preserving the
//     "dial the remembered address" default;
//   * a malformed address never reaches the daemon at all — it is caught in the
//     provider, so no request that must fail is ever sent.
import 'package:flutter_test/flutter_test.dart';
import 'package:privet_app/providers/send_preparation.dart';

import '../support/test_daemon.dart';

/// Boots a daemon that records the `send` params it was handed.
Future<({void Function() dispose, SendPreparationNotifier n, Map<String, dynamic>? Function() lastSend})>
    _boot() async {
  Map<String, dynamic>? lastSend;
  final daemon = await bootTestDaemon(scriptFromHandlers({
    'send': (id, params) {
      lastSend = Map<String, dynamic>.from(params);
      return okResponse(id, 'transfer_queued', {'transfer_id': 't-1'});
    },
  }));
  final n = daemon.container.read(sendPreparationProvider.notifier);
  return (
    dispose: daemon.dispose,
    n: n,
    lastSend: () => lastSend,
  );
}

void main() {
  test('a valid address is sent as a bare IP in the send request', () async {
    final d = await _boot();
    addTearDown(d.dispose);
    final n = d.n
      ..addFileEntry(
          SendFileEntry(path: '/a.txt', relativePath: 'a.txt', size: 1))
      ..setPeer('fp1', name: 'phone');

    n.setVia('10.29.210.120');
    expect(n.state.viaIp, '10.29.210.120');
    expect(n.state.viaError, isNull);

    final id = await n.send();
    expect(id, 't-1');
    expect(d.lastSend()!['via'], '10.29.210.120');
    expect(d.lastSend()!['device_fingerprint'], 'fp1');
  });

  test('a typed port is stripped before it reaches the engine', () async {
    // The engine reads the port from the device record; a ported `via` is an
    // invalid address, so the UI must never forward one.
    final d = await _boot();
    addTearDown(d.dispose);
    final n = d.n
      ..addFileEntry(
          SendFileEntry(path: '/a.txt', relativePath: 'a.txt', size: 1))
      ..setPeer('fp1', name: 'phone');

    n.setVia('10.29.210.120:47808');
    expect(n.state.viaIp, '10.29.210.120');
    await n.send();
    expect(d.lastSend()!['via'], '10.29.210.120');
  });

  test('an IPv6 address is sent unwrapped, without brackets', () async {
    final d = await _boot();
    addTearDown(d.dispose);
    final n = d.n
      ..addFileEntry(
          SendFileEntry(path: '/a.txt', relativePath: 'a.txt', size: 1))
      ..setPeer('fp1', name: 'phone');

    n.setVia('[fe80::1c2b:3d4e]:47808');
    expect(n.state.viaIp, 'fe80::1c2b:3d4e');
    await n.send();
    expect(d.lastSend()!['via'], 'fe80::1c2b:3d4e');
  });

  test('no address means the request omits via entirely', () async {
    // The default path must be untouched: the engine then dials the address
    // already in the device record.
    final d = await _boot();
    addTearDown(d.dispose);
    final n = d.n
      ..addFileEntry(
          SendFileEntry(path: '/a.txt', relativePath: 'a.txt', size: 1))
      ..setPeer('fp1', name: 'phone');

    expect(n.state.viaIp, isNull);
    await n.send();
    expect(d.lastSend()!.containsKey('via'), isFalse,
        reason: 'an unset override must be absent, not null or empty');
  });

  test('an invalid address is rejected in the UI and never sent', () async {
    // The daemon refuses a malformed `via` before queueing, so firing the
    // request anyway would guarantee a failure — and would leave the user
    // watching a transfer that can never start.
    final d = await _boot();
    addTearDown(d.dispose);
    final n = d.n
      ..addFileEntry(
          SendFileEntry(path: '/a.txt', relativePath: 'a.txt', size: 1))
      ..setPeer('fp1', name: 'phone');

    n.setVia('not-an-ip');
    expect(n.state.viaIp, isNull);
    expect(n.state.viaError, isNotNull);
    expect(n.state.isReady, isFalse, reason: 'an unusable address blocks sending');

    final id = await n.send();
    expect(id, isNull);
    expect(d.lastSend(), isNull, reason: 'the daemon must not be contacted');
    expect(n.state.error, n.state.viaError);
  });

  test('a hostname is rejected — the engine dials an IP, not a name', () async {
    final d = await _boot();
    addTearDown(d.dispose);
    final n = d.n
      ..addFileEntry(
          SendFileEntry(path: '/a.txt', relativePath: 'a.txt', size: 1))
      ..setPeer('fp1', name: 'phone');

    n.setVia('my-laptop.local');
    expect(n.state.viaError, isNotNull);
    await n.send();
    expect(d.lastSend(), isNull);
  });

  test('correcting a bad address clears the error and re-enables sending',
      () async {
    final d = await _boot();
    addTearDown(d.dispose);
    final n = d.n
      ..addFileEntry(
          SendFileEntry(path: '/a.txt', relativePath: 'a.txt', size: 1))
      ..setPeer('fp1', name: 'phone');

    n.setVia('999.999.999.999');
    expect(n.state.isReady, isFalse);

    n.setVia('10.29.210.120');
    expect(n.state.viaError, isNull);
    expect(n.state.viaIp, '10.29.210.120');
    expect(n.state.isReady, isTrue);
  });

  test('clearing the box drops the override and any stale error', () async {
    final d = await _boot();
    addTearDown(d.dispose);
    final n = d.n
      ..addFileEntry(
          SendFileEntry(path: '/a.txt', relativePath: 'a.txt', size: 1))
      ..setPeer('fp1', name: 'phone');

    n.setVia('10.29.210.120');
    expect(n.state.viaIp, '10.29.210.120');

    // An empty box means "use the remembered address" — it must clear the
    // override rather than send an empty or stale `via`.
    n.setVia('');
    expect(n.state.viaIp, isNull);
    expect(n.state.viaError, isNull);
    expect(n.state.isReady, isTrue);

    await n.send();
    expect(d.lastSend()!.containsKey('via'), isFalse);
  });

  test('a bad address followed by an empty box unblocks sending', () async {
    final d = await _boot();
    addTearDown(d.dispose);
    final n = d.n
      ..addFileEntry(
          SendFileEntry(path: '/a.txt', relativePath: 'a.txt', size: 1))
      ..setPeer('fp1', name: 'phone');

    n.setVia('nonsense');
    expect(n.state.isReady, isFalse);
    n.setVia('   ');
    expect(n.state.viaError, isNull);
    expect(n.state.isReady, isTrue);
  });
}
