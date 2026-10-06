import '../../utils/addr.dart';
import 'protocol.dart';

export 'protocol.dart' show IpcProtocolException;

// ---- strict field readers ------------------------------------------------
// Every DTO parse mirrors the daemon's `deny_unknown_fields`: unknown keys and
// shape mismatches fail loudly via IpcProtocolException, never silently null.

String _requireString(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v is! String) {
    throw IpcProtocolException('field "$key" must be a string');
  }
  return v;
}

int _requireInt(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v is! int) {
    throw IpcProtocolException('field "$key" must be an int');
  }
  return v;
}

bool _requireBool(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v is! bool) {
    throw IpcProtocolException('field "$key" must be a bool');
  }
  return v;
}

String? _optString(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is! String) {
    throw IpcProtocolException('field "$key" must be a string or null');
  }
  return v;
}

int? _optInt(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is! int) throw IpcProtocolException('field "$key" must be an int or null');
  return v;
}

List<String> _requireStringList(Map<String, dynamic> json, String key) {
  final v = json[key];
  if (v is! List) {
    throw IpcProtocolException('field "$key" must be a list');
  }
  return v.map((e) {
    if (e is! String) {
      throw IpcProtocolException('field "$key" elements must be strings');
    }
    return e;
  }).toList();
}

/// Reads an optional list of nested DTOs. A missing key is an *absent* field,
/// not a shape error, so it maps to an empty list — this is how additive
/// daemon fields stay backward compatible with older builds.
List<T> _optDtoList<T>(
  Map<String, dynamic> json,
  String key,
  T Function(Map<String, dynamic>) parse,
) {
  final v = json[key];
  if (v == null) return const [];
  if (v is! List) throw IpcProtocolException('field "$key" must be a list');
  return v
      .map((e) => parse(e as Map<String, dynamic>))
      .toList(growable: false);
}

void _rejectUnknown(Map<String, dynamic> json, Set<String> known) {
  final unknown = json.keys.where((k) => !known.contains(k)).toList();
  if (unknown.isNotEmpty) {
    throw IpcProtocolException('unknown fields: ${unknown.join(", ")}');
  }
}

// ---- DTO types -----------------------------------------------------------

/// One dialable address of *this* machine, as reported by `get_status`
/// (`local_addrs`). The engine only lists operational, non-loopback,
/// non-unspecified interface addresses, IPv4 first, deduped and stably
/// ordered, so the app can render them verbatim.
///
/// A machine with both wired and wireless NICs (or several IPv6 addresses)
/// reports several entries; in client-isolated networks the user reads one off
/// the screen and types/pastes it on the other device.
class LocalAddrDto {
  LocalAddrDto({
    required this.ip,
    required this.quicPort,
    required this.tcpPort,
  });

  factory LocalAddrDto.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(json, {'ip', 'quic_port', 'tcp_port'});
    return LocalAddrDto(
      ip: _requireString(json, 'ip'),
      quicPort: _requireInt(json, 'quic_port'),
      tcpPort: _requireInt(json, 'tcp_port'),
    );
  }

  final String ip;
  final int quicPort;
  final int tcpPort;

  /// `ip:quic_port`, with IPv6 wrapped in brackets so the result can be pasted
  /// straight into "pair by address" (`[fe80::1]:47808`).
  String get dialString => formatDialString(ip, quicPort);

  Map<String, dynamic> toJson() => {
        'ip': ip,
        'quic_port': quicPort,
        'tcp_port': tcpPort,
      };
}

class DaemonStatus {
  DaemonStatus({
    required this.protocolVersion,
    required this.daemonVersion,
    required this.sessionId,
    required this.deviceFingerprint,
    required this.quicAddr,
    required this.tcpAddr,
    required this.activeTransfers,
    this.localAddrs = const [],
  });

  factory DaemonStatus.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(json, {
      'protocol_version', 'daemon_version', 'session_id', 'device_fingerprint',
      'quic_addr', 'tcp_addr', 'active_transfers', 'local_addrs',
    });
    return DaemonStatus(
      protocolVersion: _requireInt(json, 'protocol_version'),
      daemonVersion: _requireString(json, 'daemon_version'),
      sessionId: _requireString(json, 'session_id'),
      deviceFingerprint: _requireString(json, 'device_fingerprint'),
      quicAddr: _requireString(json, 'quic_addr'),
      tcpAddr: _requireString(json, 'tcp_addr'),
      activeTransfers: _requireStringList(json, 'active_transfers'),
      // Additive field: daemons predating it omit `local_addrs` entirely, and
      // that is not an error — it means "no addresses to offer" (empty list).
      localAddrs:
          _optDtoList(json, 'local_addrs', LocalAddrDto.fromJson),
    );
  }

  final int protocolVersion;
  final String daemonVersion;
  final String sessionId;
  final String deviceFingerprint;
  final String quicAddr;
  final String tcpAddr;
  final List<String> activeTransfers;

  /// This machine's own dialable addresses. Empty when the daemon predates the
  /// field, or when no interface qualifies.
  final List<LocalAddrDto> localAddrs;

  Map<String, dynamic> toJson() => {
        'protocol_version': protocolVersion,
        'daemon_version': daemonVersion,
        'session_id': sessionId,
        'device_fingerprint': deviceFingerprint,
        'quic_addr': quicAddr,
        'tcp_addr': tcpAddr,
        'active_transfers': activeTransfers,
        'local_addrs': localAddrs.map((a) => a.toJson()).toList(),
      };
}

class IdentityDto {
  IdentityDto({required this.deviceFingerprint, required this.deviceName});

  factory IdentityDto.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(json, {'device_fingerprint', 'device_name'});
    return IdentityDto(
      deviceFingerprint: _requireString(json, 'device_fingerprint'),
      deviceName: _requireString(json, 'device_name'),
    );
  }

  final String deviceFingerprint;
  final String deviceName;

  Map<String, dynamic> toJson() => {
        'device_fingerprint': deviceFingerprint,
        'device_name': deviceName,
      };
}

class CandidateAddressDto {
  CandidateAddressDto({
    required this.ip,
    required this.quicPort,
    required this.tcpPort,
    required this.lastSeenMs,
  });

  factory CandidateAddressDto.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(json, {'ip', 'quic_port', 'tcp_port', 'last_seen_ms'});
    return CandidateAddressDto(
      ip: _requireString(json, 'ip'),
      quicPort: _requireInt(json, 'quic_port'),
      tcpPort: _requireInt(json, 'tcp_port'),
      lastSeenMs: _requireInt(json, 'last_seen_ms'),
    );
  }

  final String ip;
  final int quicPort;
  final int tcpPort;
  final int lastSeenMs;

  Map<String, dynamic> toJson() => {
        'ip': ip,
        'quic_port': quicPort,
        'tcp_port': tcpPort,
        'last_seen_ms': lastSeenMs,
      };
}

class PeerDto {
  PeerDto({
    required this.deviceFingerprint,
    required this.deviceName,
    required this.state,
    required this.lastBeaconMs,
    required this.candidates,
  });

  factory PeerDto.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(json, {
      'device_fingerprint', 'device_name', 'state', 'last_beacon_ms',
      'candidates',
    });
    final candidates = json['candidates'];
    if (candidates is! List) {
      throw IpcProtocolException('field "candidates" must be a list');
    }
    return PeerDto(
      deviceFingerprint: _requireString(json, 'device_fingerprint'),
      deviceName: _requireString(json, 'device_name'),
      state: _requireString(json, 'state'),
      lastBeaconMs: _requireInt(json, 'last_beacon_ms'),
      candidates: candidates
          .map((e) => CandidateAddressDto.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  final String deviceFingerprint;
  final String deviceName;
  final String state;
  final int lastBeaconMs;
  final List<CandidateAddressDto> candidates;

  /// Whether the daemon currently considers this peer reachable. The discovery
  /// engine drives records Seen -> Resolved -> Live as a peer is beaconed and
  /// connected, and flags it Stale (no beacon for 3 min) then Lost (5 min) once
  /// it goes quiet. Absent means it sent a goodbye. Anything else — seen,
  /// resolved, live — is treated as online.
  bool get isOnline => const {'seen', 'resolved', 'live'}.contains(state);

  /// States that mean the peer has left the network and is not coming back on
  /// its own (goodbye sent, or the lost-timeout elapsed).
  bool get isGone => state == 'lost' || state == 'absent';

  Map<String, dynamic> toJson() => {
        'device_fingerprint': deviceFingerprint,
        'device_name': deviceName,
        'state': state,
        'last_beacon_ms': lastBeaconMs,
        'candidates': candidates.map((c) => c.toJson()).toList(),
      };
}

class TrustedPeerDto {
  TrustedPeerDto({
    required this.deviceFingerprint,
    required this.deviceName,
    required this.trustState,
    required this.spkiHex,
    required this.firstPairedTs,
    required this.lastSeenTs,
    required this.revokedTs,
    required this.revocationReason,
  });

  factory TrustedPeerDto.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(json, {
      'device_fingerprint', 'device_name', 'trust_state', 'spki_hex',
      'first_paired_ts', 'last_seen_ts', 'revoked_ts', 'revocation_reason',
    });
    return TrustedPeerDto(
      deviceFingerprint: _requireString(json, 'device_fingerprint'),
      deviceName: _requireString(json, 'device_name'),
      trustState: _requireString(json, 'trust_state'),
      spkiHex: _requireString(json, 'spki_hex'),
      firstPairedTs: _requireInt(json, 'first_paired_ts'),
      lastSeenTs: _requireInt(json, 'last_seen_ts'),
      revokedTs: _optInt(json, 'revoked_ts'),
      revocationReason: _optString(json, 'revocation_reason'),
    );
  }

  final String deviceFingerprint;
  final String deviceName;
  final String trustState;
  final String spkiHex;
  final int firstPairedTs;
  final int lastSeenTs;
  final int? revokedTs;
  final String? revocationReason;

  Map<String, dynamic> toJson() => {
        'device_fingerprint': deviceFingerprint,
        'device_name': deviceName,
        'trust_state': trustState,
        'spki_hex': spkiHex,
        'first_paired_ts': firstPairedTs,
        'last_seen_ts': lastSeenTs,
        'revoked_ts': revokedTs,
        'revocation_reason': revocationReason,
      };
}

class TransferSummaryDto {
  TransferSummaryDto({
    required this.transferId,
    required this.fileCount,
    required this.totalBytes,
  });

  factory TransferSummaryDto.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(json, {'transfer_id', 'file_count', 'total_bytes'});
    return TransferSummaryDto(
      transferId: _requireString(json, 'transfer_id'),
      fileCount: _requireInt(json, 'file_count'),
      totalBytes: _requireInt(json, 'total_bytes'),
    );
  }

  final String transferId;
  final int fileCount;
  final int totalBytes;

  Map<String, dynamic> toJson() => {
        'transfer_id': transferId,
        'file_count': fileCount,
        'total_bytes': totalBytes,
      };
}

class HistoryEntryDto {
  HistoryEntryDto({
    required this.transferId,
    required this.direction,
    required this.peerDeviceFingerprint,
    required this.peerName,
    required this.rootName,
    required this.fileCount,
    required this.totalBytes,
    required this.status,
    required this.startedTs,
    required this.finishedTs,
  });

  factory HistoryEntryDto.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(json, {
      'transfer_id', 'direction', 'peer_device_fingerprint', 'peer_name',
      'root_name', 'file_count', 'total_bytes', 'status', 'started_ts',
      'finished_ts',
    });
    return HistoryEntryDto(
      transferId: _requireString(json, 'transfer_id'),
      direction: _requireString(json, 'direction'),
      peerDeviceFingerprint: _optString(json, 'peer_device_fingerprint'),
      peerName: _optString(json, 'peer_name'),
      rootName: _optString(json, 'root_name'),
      fileCount: _requireInt(json, 'file_count'),
      totalBytes: _requireInt(json, 'total_bytes'),
      status: _requireString(json, 'status'),
      startedTs: _requireInt(json, 'started_ts'),
      finishedTs: _optInt(json, 'finished_ts'),
    );
  }

  final String transferId;
  final String direction;
  final String? peerDeviceFingerprint;
  final String? peerName;
  final String? rootName;
  final int fileCount;
  final int totalBytes;
  final String status;
  final int startedTs;
  final int? finishedTs;

  Map<String, dynamic> toJson() => {
        'transfer_id': transferId,
        'direction': direction,
        'peer_device_fingerprint': peerDeviceFingerprint,
        'peer_name': peerName,
        'root_name': rootName,
        'file_count': fileCount,
        'total_bytes': totalBytes,
        'status': status,
        'started_ts': startedTs,
        'finished_ts': finishedTs,
      };
}

class HistoryFileDto {
  HistoryFileDto({
    required this.relativePath,
    required this.absolutePath,
    required this.size,
    required this.status,
  });

  factory HistoryFileDto.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(json, {'relative_path', 'absolute_path', 'size', 'status'});
    return HistoryFileDto(
      relativePath: _requireString(json, 'relative_path'),
      absolutePath: _optString(json, 'absolute_path'),
      size: _requireInt(json, 'size'),
      status: _requireString(json, 'status'),
    );
  }

  final String relativePath;
  final String? absolutePath;
  final int size;
  final String status;

  Map<String, dynamic> toJson() => {
        'relative_path': relativePath,
        'absolute_path': absolutePath,
        'size': size,
        'status': status,
      };
}

class HistoryDetailDto {
  HistoryDetailDto({
    required this.transferId,
    required this.direction,
    required this.peerDeviceFingerprint,
    required this.peerName,
    required this.rootName,
    required this.status,
    required this.startedTs,
    required this.finishedTs,
    required this.files,
  });

  factory HistoryDetailDto.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(json, {
      'transfer_id', 'direction', 'peer_device_fingerprint', 'peer_name',
      'root_name', 'status', 'started_ts', 'finished_ts', 'files',
    });
    final files = json['files'];
    if (files is! List) {
      throw IpcProtocolException('field "files" must be a list');
    }
    return HistoryDetailDto(
      transferId: _requireString(json, 'transfer_id'),
      direction: _requireString(json, 'direction'),
      peerDeviceFingerprint: _optString(json, 'peer_device_fingerprint'),
      peerName: _optString(json, 'peer_name'),
      rootName: _optString(json, 'root_name'),
      status: _requireString(json, 'status'),
      startedTs: _requireInt(json, 'started_ts'),
      finishedTs: _optInt(json, 'finished_ts'),
      files: files
          .map((e) => HistoryFileDto.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  final String transferId;
  final String direction;
  final String? peerDeviceFingerprint;
  final String? peerName;
  final String? rootName;
  final String status;
  final int startedTs;
  final int? finishedTs;
  final List<HistoryFileDto> files;

  Map<String, dynamic> toJson() => {
        'transfer_id': transferId,
        'direction': direction,
        'peer_device_fingerprint': peerDeviceFingerprint,
        'peer_name': peerName,
        'root_name': rootName,
        'status': status,
        'started_ts': startedTs,
        'finished_ts': finishedTs,
        'files': files.map((f) => f.toJson()).toList(),
      };
}

class RuntimeConfigDto {
  RuntimeConfigDto({
    required this.acceptAllTrusted,
    required this.collisionPolicy,
    required this.saveDir,
  });

  factory RuntimeConfigDto.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(json, {'accept_all_trusted', 'collision_policy', 'save_dir'});
    return RuntimeConfigDto(
      acceptAllTrusted: _requireBool(json, 'accept_all_trusted'),
      collisionPolicy: _requireString(json, 'collision_policy'),
      saveDir: _requireString(json, 'save_dir'),
    );
  }

  final bool acceptAllTrusted;
  final String collisionPolicy;
  final String saveDir;

  Map<String, dynamic> toJson() => {
        'accept_all_trusted': acceptAllTrusted,
        'collision_policy': collisionPolicy,
        'save_dir': saveDir,
      };
}

class PairingCodeDto {
  PairingCodeDto({required this.code, required this.validitySecs});

  factory PairingCodeDto.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(json, {'code', 'validity_secs'});
    return PairingCodeDto(
      code: _requireString(json, 'code'),
      validitySecs: _requireInt(json, 'validity_secs'),
    );
  }

  final String code;
  final int validitySecs;

  Map<String, dynamic> toJson() => {
        'code': code,
        'validity_secs': validitySecs,
      };
}

class PairingResultDto {
  PairingResultDto({required this.paired, required this.deviceFingerprint});

  factory PairingResultDto.fromJson(Map<String, dynamic> json) {
    _rejectUnknown(json, {'paired', 'device_fingerprint'});
    return PairingResultDto(
      paired: _requireBool(json, 'paired'),
      deviceFingerprint: _optString(json, 'device_fingerprint'),
    );
  }

  final bool paired;
  final String? deviceFingerprint;

  Map<String, dynamic> toJson() => {
        'paired': paired,
        'device_fingerprint': deviceFingerprint,
      };
}
