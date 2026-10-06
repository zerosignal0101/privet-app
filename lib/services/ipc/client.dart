import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'dto.dart';
import 'events.dart';
import 'protocol.dart';
import 'requests.dart';
import 'transport.dart';

export 'events.dart';
export 'transport.dart';

class PrivetIpcException implements Exception {
  PrivetIpcException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'PrivetIpcException($code): $message';
}

/// The result of establishing (or resuming) a client session: the daemon
/// snapshot, the replayed events, and the derived reconnect signals the app
/// uses to decide whether to refresh all snapshots.
class ConnectedSession {
  ConnectedSession({
    required this.status,
    required this.replay,
    required this.oldestAvailable,
    required this.latest,
    required this.cursor,
    required this.gap,
    required this.sessionChanged,
  });
  final DaemonStatus status;
  final List<PrivetEvent> replay;
  final int? oldestAvailable;
  final int latest;
  final int? cursor;
  final bool gap;
  final bool sessionChanged;
}

/// A single-connection IPC client. One reader task, a pending
/// request-id/oneshot map, and a broadcast live-event stream. Never
/// auto-reconnects; the supervisor owns reconnection via a fresh `connect()`.
class PrivetIpcClient {
  PrivetIpcClient(this._transport, {this.timeout = const Duration(seconds: 30)});
  final Transport _transport;
  final Duration timeout;

  TransportConnection? _conn;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _liveEvents = StreamController<PrivetEvent>.broadcast();
  int? _lastApplied;
  bool _sessionActive = false;

  bool get isConnected => _conn != null;
  Stream<PrivetEvent> get events => _liveEvents.stream;

  Future<ConnectedSession> connect({int? afterSequence, String? previousSessionId}) async {
    _conn = await _transport.connect();
    _runReader(_conn!.incoming);
    final status = DaemonStatus.fromJson(
        (await callRaw('get_status')) as Map<String, dynamic>);
    final replayPayload = (await callRaw('subscribe_events',
        {'after_sequence': ?afterSequence})) as Map<String, dynamic>;
    final replayJson = (replayPayload['events'] as List?) ?? const [];
    final oldest = (replayPayload['oldest_available'] as num?)?.toInt();
    final latest = (replayPayload['latest'] as num?)?.toInt() ?? 0;
    final replay = replayJson
        .map((e) => parseEventMessage((e as Map<String, dynamic>)))
        .toList();
    _lastApplied = latest;
    final gap = afterSequence != null &&
        oldest != null &&
        afterSequence + 1 < oldest;
    // A first connect (no previous session) IS a new session; otherwise the
    // session changed only when the id differs.
    final sessionChanged =
        previousSessionId == null || previousSessionId != status.sessionId;
    _sessionActive = true;
    return ConnectedSession(
      status: status,
      replay: replay,
      oldestAvailable: oldest,
      latest: latest,
      cursor: _lastApplied,
      gap: gap,
      sessionChanged: sessionChanged,
    );
  }

  void _runReader(Stream<List<int>> incoming) {
    var buffer = BytesBuilder(copy: false);
    incoming.listen((chunk) {
      buffer.add(chunk);
      while (true) {
        final text = IpcFrameCodec.decode(buffer);
        if (text == null) break;
        _onFrame(text);
      }
    }, onError: (Object e, StackTrace st) {
      _failPending(PrivetIpcException('transport', e.toString()));
    }, onDone: () {
      _failPending(PrivetIpcException('closed', 'connection closed'));
    }, cancelOnError: true);
  }

  void _onFrame(String text) {
    final message = jsonDecode(text) as Map<String, dynamic>;
    final type = message['type'];
    if (type == 'response') {
      final requestId = message['request_id'] as String;
      final completer = _pending.remove(requestId);
      if (completer != null) completer.complete(message);
    } else if (type == 'event') {
      final event = parseEventMessage(message);
      if (_sessionActive && _lastApplied != null && event.sequence <= _lastApplied!) {
        return; // dedupe replay overlap
      }
      _lastApplied = event.sequence;
      _liveEvents.add(event);
    } else {
      _failPending(PrivetIpcException('protocol', 'unknown server message type: $type'));
    }
  }

  void _failPending(PrivetIpcException error) {
    _sessionActive = false;
    final pending = _pending.values.toList();
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }

  /// Returns the decoded `data` half of a response payload — a map, a list
  /// (for `peers`/`history`), or `null` for `ack`. Throws [PrivetIpcException]
  /// on a daemon error payload.
  Future<dynamic> callRaw(String method, [Map<String, dynamic>? params]) async {
    final conn = _conn;
    if (conn == null) throw PrivetIpcException('closed', 'client is not connected');
    final requestId = newRequestId();
    final completer = Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;
    conn.out.add(IpcFrameCodec.encode(jsonEncode({
      'protocol_version': ipcProtocolVersion,
      'request_id': requestId,
      'request': {'method': method, 'params': ?params},
    })));
    final result = await completer.future.timeout(timeout,
        onTimeout: () => throw PrivetIpcException('timeout', 'request timed out'));
    final payload = result['payload'];
    final error = result['error'];
    if (error != null) {
      throw PrivetIpcException(error['code'] as String, error['message'] as String);
    }
    if (payload == null || payload is! Map<String, dynamic>) {
      throw PrivetIpcException('protocol', 'response must contain exactly one of payload/error');
    }
    // payload is {"kind":..., "data":...}; unwrap to the data half.
    return payload['data'];
  }

  // ---- typed helpers ------------------------------------------------------

  Future<DaemonStatus> getStatus() async =>
      DaemonStatus.fromJson((await callRaw('get_status')) as Map<String, dynamic>);
  Future<IdentityDto> getIdentity() async =>
      IdentityDto.fromJson((await callRaw('get_identity')) as Map<String, dynamic>);
  Future<List<PeerDto>> listPeers() async => ((await callRaw('list_peers')) as List)
      .map((e) => PeerDto.fromJson(e as Map<String, dynamic>))
      .toList();
  Future<void> refreshPeers() async => callRaw('refresh_peers');
  Future<List<TrustedPeerDto>> listTrusted() async => ((await callRaw('list_trusted')) as List)
      .map((e) => TrustedPeerDto.fromJson(e as Map<String, dynamic>))
      .toList();
  /// Dials [ip] and reports who answered there.
  ///
  /// An address does not name a device, so this is how one becomes an identity:
  /// the daemon completes the same handshake pairing performs before it asks for
  /// a code. [ip] is a bare address (as for [send]'s `via`); [quicPort]/[tcpPort]
  /// are null unless the user typed a port, in which case the daemon uses those
  /// instead of its own.
  Future<ResolvedAddressDto> resolveAddress(String ip,
          {int? quicPort, int? tcpPort}) async =>
      ResolvedAddressDto.fromJson((await callRaw('resolve_address', {
        'ip': ip,
        'quic_port': quicPort,
        'tcp_port': tcpPort,
      })) as Map<String, dynamic>);

  Future<PairingCodeDto> generatePairingCode() async =>
      PairingCodeDto.fromJson((await callRaw('generate_pairing_code')) as Map<String, dynamic>);
  Future<PairingResultDto> pair({
    String? fingerprint,
    String? ip,
    int? quicPort,
    int? tcpPort,
    required String code,
  }) async {
    final data = await callRaw('pair', {
      if (fingerprint != null)
        'peer': {'kind': 'discovered', 'device_fingerprint': fingerprint}
      else
        'peer': {'kind': 'endpoint', 'ip': ip, 'quic_port': quicPort, 'tcp_port': tcpPort},
      'code': code,
    });
    return PairingResultDto.fromJson(data as Map<String, dynamic>);
  }
  Future<void> revokePeer(String fp, {String reason = ''}) async =>
      callRaw('revoke_peer', {'device_fingerprint': fp, 'reason': reason});
  Future<void> forgetPeer(String fp) async =>
      callRaw('forget_peer', {'device_fingerprint': fp});
  /// Queues a send. [via] optionally overrides the destination address with a
  /// **bare IP** — see [reqSend] for why it carries no port. The daemon rejects
  /// a malformed `via` with an invalid-address error before queueing, so the
  /// UI validates first rather than firing a request that cannot succeed.
  Future<String> send(List<String> paths, String fingerprint,
      {String? asName, String? via}) async {
    final data = await callRaw('send', {
      'paths': paths,
      'device_fingerprint': fingerprint,
      'as_name': ?asName,
      'via': ?via,
    });
    return (data as Map<String, dynamic>)['transfer_id'] as String;
  }
  Future<String> resumeTransfer(String id) async =>
      (await callRaw('resume_transfer', {'transfer_id': id}))['transfer_id'] as String;
  Future<String> resendTransfer(String id) async =>
      (await callRaw('resend_transfer', {'transfer_id': id}))['transfer_id'] as String;
  Future<void> acceptTransfer(String id, {bool accept = true}) async =>
      callRaw('accept_transfer', {'transfer_id': id, 'accept': accept});
  Future<void> cancelTransfer(String id) async =>
      callRaw('cancel_transfer', {'transfer_id': id});
  Future<void> pauseTransfer(String id) async =>
      callRaw('pause_transfer', {'transfer_id': id});
  Future<void> continueTransfer(String id) async =>
      callRaw('continue_transfer', {'transfer_id': id});
  Future<List<HistoryEntryDto>> listHistory({String? peer, int limit = 100}) async =>
      ((await callRaw('list_history', {'peer': ?peer, 'limit': limit})) as List)
          .map((e) => HistoryEntryDto.fromJson(e as Map<String, dynamic>))
          .toList();
  Future<HistoryDetailDto> getHistoryDetail(String id) async => HistoryDetailDto.fromJson(
      (await callRaw('get_history_detail', {'transfer_id': id})) as Map<String, dynamic>);
  Future<void> deleteHistory(String id) async =>
      callRaw('delete_history', {'transfer_id': id});
  Future<RuntimeConfigDto> getRuntimeConfig() async =>
      RuntimeConfigDto.fromJson((await callRaw('get_runtime_config')) as Map<String, dynamic>);
  Future<RuntimeConfigDto> setRuntimeConfig({
    bool? acceptAllTrusted,
    String? collisionPolicy,
    String? saveDir,
  }) async {
    final data = await callRaw('set_runtime_config', {
      'accept_all_trusted': ?acceptAllTrusted,
      'collision_policy': ?collisionPolicy,
      'save_dir': ?saveDir,
    });
    return RuntimeConfigDto.fromJson(data as Map<String, dynamic>);
  }
  Future<void> shutdown() async => callRaw('shutdown');

  Future<void> close() async {
    _failPending(PrivetIpcException('closed', 'client closed'));
    await _conn?.out.close();
    await _liveEvents.close();
    _conn = null;
  }
}
