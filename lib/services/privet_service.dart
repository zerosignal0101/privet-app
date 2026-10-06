import 'ipc/client.dart';
import 'ipc/dto.dart';

/// Typed facade over the daemon IPC contract. The UI layer (Plan 3) consumes
/// only this class; it never touches Transport or framing.
class PrivetService {
  PrivetService(this._client);
  final PrivetIpcClient _client;

  Stream<PrivetEvent> get events => _client.events;

  Future<ConnectedSession> connect({int? afterSequence, String? previousSessionId}) =>
      _client.connect(afterSequence: afterSequence, previousSessionId: previousSessionId);
  Future<DaemonStatus> status() => _client.getStatus();
  Future<IdentityDto> identity() => _client.getIdentity();
  Future<List<PeerDto>> peers() => _client.listPeers();
  Future<void> refreshPeers() => _client.refreshPeers();
  Future<List<TrustedPeerDto>> trusted() => _client.listTrusted();
  /// Dials [ip] and reports who answered there (see `resolve_address`).
  ///
  /// This is the only way an address becomes an identity: a device paired on one
  /// network and met again on another has no remembered address to look up, so
  /// the handshake is what tells the app whether the thing at that address is a
  /// device it already has. Pass [quicPort]/[tcpPort] only when the user typed a
  /// port; otherwise the daemon dials its own.
  Future<ResolvedAddressDto> resolveAddress(String ip, {int? quicPort, int? tcpPort}) =>
      _client.resolveAddress(ip, quicPort: quicPort, tcpPort: tcpPort);
  Future<PairingCodeDto> generatePairingCode() => _client.generatePairingCode();
  Future<PairingResultDto> pair({
    required String code,
    String? fingerprint,
    String? ip,
    int? quicPort,
    int? tcpPort,
  }) =>
      _client.pair(
          code: code,
          fingerprint: fingerprint,
          ip: ip,
          quicPort: quicPort,
          tcpPort: tcpPort);
  Future<void> revokePeer(String fingerprint, {String reason = ''}) =>
      _client.revokePeer(fingerprint, reason: reason);
  Future<void> forgetPeer(String fingerprint) => _client.forgetPeer(fingerprint);
  /// [via] is an optional explicit destination as a **bare IP** (no port — the
  /// engine takes the port from the device record). Null means "use the address
  /// the engine already has for this peer".
  Future<String> send(List<String> paths, String fingerprint,
          {String? asName, String? via}) =>
      _client.send(paths, fingerprint, asName: asName, via: via);
  Future<String> resumeTransfer(String transferId) => _client.resumeTransfer(transferId);
  Future<String> resendTransfer(String transferId) => _client.resendTransfer(transferId);
  Future<void> acceptTransfer(String transferId, {bool accept = true}) =>
      _client.acceptTransfer(transferId, accept: accept);
  Future<void> cancelTransfer(String transferId) => _client.cancelTransfer(transferId);
  Future<void> pauseTransfer(String transferId) => _client.pauseTransfer(transferId);
  Future<void> continueTransfer(String transferId) => _client.continueTransfer(transferId);
  Future<List<HistoryEntryDto>> history({String? peer, int limit = 100}) =>
      _client.listHistory(peer: peer, limit: limit);
  Future<HistoryDetailDto> historyDetail(String transferId) =>
      _client.getHistoryDetail(transferId);
  Future<void> deleteHistory(String transferId) => _client.deleteHistory(transferId);
  Future<RuntimeConfigDto> runtimeConfig() => _client.getRuntimeConfig();
  Future<RuntimeConfigDto> setRuntimeConfig({
    bool? acceptAllTrusted,
    String? collisionPolicy,
    String? saveDir,
  }) =>
      _client.setRuntimeConfig(
          acceptAllTrusted: acceptAllTrusted,
          collisionPolicy: collisionPolicy,
          saveDir: saveDir);
  Future<void> shutdown() => _client.shutdown();
}
