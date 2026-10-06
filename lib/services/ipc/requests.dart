import 'dart:convert';

import 'protocol.dart';

/// Dev-time request-id stand-in. The daemon only requires uniqueness within a
/// connection. Replace with a real UUID in the UI plan.
String newRequestId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-'
    '${(Object().hashCode.toUnsigned(32)).toRadixString(16)}';

/// Returns the full client envelope `{protocol_version, request_id, request}`
/// for [method] and optional [params], ready for framing.
Map<String, dynamic> requestEnvelope(String method, [Map<String, dynamic>? params]) {
  return jsonDecode(utf8.decode(encodeRequest(newRequestId(), method, params)))
      as Map<String, dynamic>;
}

Map<String, dynamic> reqPing() => requestEnvelope('ping');
Map<String, dynamic> reqGetStatus() => requestEnvelope('get_status');
Map<String, dynamic> reqGetIdentity() => requestEnvelope('get_identity');
Map<String, dynamic> reqListPeers() => requestEnvelope('list_peers');
Map<String, dynamic> reqRefreshPeers() => requestEnvelope('refresh_peers');
Map<String, dynamic> reqListTrusted() => requestEnvelope('list_trusted');
/// `resolve_address`: dial [ip] and report who answers there.
///
/// [ip] is a bare address, exactly like `via` on a send — no port. The daemon
/// dials its *own* listener ports when [quicPort]/[tcpPort] are null, which is
/// what a peer built the same way answers on; pass them only when the user typed
/// a port themselves.
///
/// This is how an address becomes a device: the daemon completes the identity
/// handshake pairing performs before it asks for a code, so the answer says
/// whether the device there is one this daemon already trusts.
Map<String, dynamic> reqResolveAddress(String ip, {int? quicPort, int? tcpPort}) =>
    requestEnvelope('resolve_address', {
      'ip': ip,
      'quic_port': quicPort,
      'tcp_port': tcpPort,
    });
Map<String, dynamic> reqGeneratePairingCode() => requestEnvelope('generate_pairing_code');
Map<String, dynamic> reqPair({
  String? fingerprint,
  String? ip,
  int? quicPort,
  int? tcpPort,
  required String code,
}) {
  return requestEnvelope('pair', {
    if (fingerprint != null)
      'peer': {'kind': 'discovered', 'device_fingerprint': fingerprint}
    else
      'peer': {
        'kind': 'endpoint',
        'ip': ip,
        'quic_port': quicPort,
        'tcp_port': tcpPort,
      },
    'code': code,
  });
}
Map<String, dynamic> reqRevokePeer(String fp, String reason) =>
    requestEnvelope('revoke_peer', {'device_fingerprint': fp, 'reason': reason});
Map<String, dynamic> reqForgetPeer(String fp) =>
    requestEnvelope('forget_peer', {'device_fingerprint': fp});
/// `send` with an optional explicit destination.
///
/// [via] must be a **bare IP** (IPv4 or IPv6, brackets optional), never
/// `ip:port`: the engine looks the port up in the device record it already
/// holds, so a port here is not just ignored — a ported string is rejected as
/// an invalid address before the transfer is queued. Omitting [via] (null)
/// keeps the default behaviour of dialling whatever the record says.
Map<String, dynamic> reqSend(
  List<String> paths,
  String fingerprint, {
  String? asName,
  String? via,
}) =>
    requestEnvelope('send', {
      'paths': paths,
      'device_fingerprint': fingerprint,
      'as_name': ?asName,
      'via': ?via,
    });
Map<String, dynamic> reqResumeTransfer(String id) =>
    requestEnvelope('resume_transfer', {'transfer_id': id});
Map<String, dynamic> reqResendTransfer(String id) =>
    requestEnvelope('resend_transfer', {'transfer_id': id});
Map<String, dynamic> reqAcceptTransfer(String id, bool accept) =>
    requestEnvelope('accept_transfer', {'transfer_id': id, 'accept': accept});
Map<String, dynamic> reqCancelTransfer(String id) =>
    requestEnvelope('cancel_transfer', {'transfer_id': id});
Map<String, dynamic> reqPauseTransfer(String id) =>
    requestEnvelope('pause_transfer', {'transfer_id': id});
Map<String, dynamic> reqContinueTransfer(String id) =>
    requestEnvelope('continue_transfer', {'transfer_id': id});
Map<String, dynamic> reqListHistory({String? peer, int limit = 100}) =>
    requestEnvelope('list_history', {
      'peer': ?peer,
      'limit': limit,
    });
Map<String, dynamic> reqGetHistoryDetail(String id) =>
    requestEnvelope('get_history_detail', {'transfer_id': id});
Map<String, dynamic> reqDeleteHistory(String id) =>
    requestEnvelope('delete_history', {'transfer_id': id});
Map<String, dynamic> reqGetRuntimeConfig() => requestEnvelope('get_runtime_config');
Map<String, dynamic> reqSetRuntimeConfig({
  bool? acceptAllTrusted,
  String? collisionPolicy,
  String? saveDir,
}) =>
    requestEnvelope('set_runtime_config', {
      'accept_all_trusted': ?acceptAllTrusted,
      'collision_policy': ?collisionPolicy,
      'save_dir': ?saveDir,
    });
Map<String, dynamic> reqSubscribeEvents({int? afterSequence}) =>
    requestEnvelope('subscribe_events', {
      'after_sequence': ?afterSequence,
    });
Map<String, dynamic> reqShutdown() => requestEnvelope('shutdown');
