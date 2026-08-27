import 'dto.dart';

export 'protocol.dart' show IpcProtocolException;

/// A daemon event. `kind` is the snake_case name-tag from the wire; the parsed
/// fields mirror the daemon's event payloads (spec 09 §7).
sealed class PrivetEvent {
  PrivetEvent(this.sequence);
  final int sequence;
  String get kind;
}

class DeviceDiscoveredEvent extends PrivetEvent {
  DeviceDiscoveredEvent(super.sequence, this.deviceFingerprint, this.deviceName);
  final String deviceFingerprint;
  final String deviceName;
  @override
  String get kind => 'device_discovered';
}

class DeviceLostEvent extends PrivetEvent {
  DeviceLostEvent(super.sequence, this.deviceFingerprint);
  final String deviceFingerprint;
  @override
  String get kind => 'device_lost';
}

class PairingRequestedEvent extends PrivetEvent {
  PairingRequestedEvent(super.sequence, this.deviceFingerprint);
  final String deviceFingerprint;
  @override
  String get kind => 'pairing_requested';
}

class PairingResultEvent extends PrivetEvent {
  PairingResultEvent(super.sequence, this.deviceFingerprint, this.success, this.error);
  final String deviceFingerprint;
  final bool success;
  final String? error;
  @override
  String get kind => 'pairing_result';
}

class TransferPreparingEvent extends PrivetEvent {
  TransferPreparingEvent(super.sequence, this.transferId);
  final String transferId;
  @override
  String get kind => 'transfer_preparing';
}

class TransferPreparingProgressEvent extends PrivetEvent {
  TransferPreparingProgressEvent(
      super.sequence, this.transferId, this.scannedBytes, this.totalBytes);
  final String transferId;
  final int scannedBytes;
  final int totalBytes;
  @override
  String get kind => 'transfer_preparing_progress';
}

class TransferOfferedEvent extends PrivetEvent {
  TransferOfferedEvent(super.sequence, this.transferId, this.fileCount, this.totalBytes);
  final String transferId;
  final int fileCount;
  final int totalBytes;
  @override
  String get kind => 'transfer_offered';
}

class TransferProgressEvent extends PrivetEvent {
  TransferProgressEvent(
      super.sequence, this.transferId, this.verifiedBytes, this.totalBytes);
  final String transferId;
  final int verifiedBytes;
  final int totalBytes;
  @override
  String get kind => 'transfer_progress';
}

class TransferReconnectingEvent extends PrivetEvent {
  TransferReconnectingEvent(
      super.sequence, this.transferId, this.attempt, this.backoffMs);
  final String transferId;
  final int attempt;
  final int backoffMs;
  @override
  String get kind => 'transfer_reconnecting';
}

class TransferResumedEvent extends PrivetEvent {
  TransferResumedEvent(super.sequence, this.transferId);
  final String transferId;
  @override
  String get kind => 'transfer_resumed';
}

class TransferPausedEvent extends PrivetEvent {
  TransferPausedEvent(super.sequence, this.transferId, this.reason);
  final String transferId;
  final String reason;
  @override
  String get kind => 'transfer_paused';
}

class TransferCompletedEvent extends PrivetEvent {
  TransferCompletedEvent(super.sequence, this.transferId);
  final String transferId;
  @override
  String get kind => 'transfer_completed';
}

class TransferCancelledEvent extends PrivetEvent {
  TransferCancelledEvent(super.sequence, this.transferId);
  final String transferId;
  @override
  String get kind => 'transfer_cancelled';
}

class TransferFailedEvent extends PrivetEvent {
  TransferFailedEvent(
      super.sequence, this.transferId, this.errorCode, this.retryable, this.partKept);
  final String transferId;
  final String errorCode;
  final bool retryable;
  final bool partKept;
  @override
  String get kind => 'transfer_failed';
}

class IncomingConnectionEvent extends PrivetEvent {
  IncomingConnectionEvent(super.sequence, this.deviceFingerprint);
  final String deviceFingerprint;
  @override
  String get kind => 'incoming_connection';
}

class RuntimeConfigChangedEvent extends PrivetEvent {
  RuntimeConfigChangedEvent(super.sequence, this.config);
  final RuntimeConfigDto config;
  @override
  String get kind => 'runtime_config_changed';
}

class DaemonStoppingEvent extends PrivetEvent {
  DaemonStoppingEvent(super.sequence);
  @override
  String get kind => 'daemon_stopping';
}

Map<String, dynamic> _data(Map<String, dynamic> event, String name) {
  final data = event['data'];
  if (data != null && data is! Map<String, dynamic>) {
    throw IpcProtocolException('event "$name" data must be an object or null');
  }
  return (data as Map<String, dynamic>?) ?? const {};
}

int _i(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is! int) throw IpcProtocolException('event field "$key" must be an int');
  return v;
}

String _s(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is! String) throw IpcProtocolException('event field "$key" must be a string');
  return v;
}

bool _b(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is! bool) throw IpcProtocolException('event field "$key" must be a bool');
  return v;
}

/// Parses a server event message `{"sequence":N,"event":{"name":...,"data":...}}`.
/// Unknown event names fail loudly; data fields not present in the daemon's
/// payload are ignored (the daemon's `Event` enum is not deny_unknown_fields).
PrivetEvent parseEventMessage(Map<String, dynamic> message) {
  final sequence = _i(message, 'sequence');
  final event = message['event'];
  if (event is! Map<String, dynamic>) {
    throw IpcProtocolException('event must be an object');
  }
  final name = _s(event, 'name');
  final data = _data(event, name);
  return switch (name) {
    'device_discovered' =>
        DeviceDiscoveredEvent(sequence, _s(data, 'device_fingerprint'), _s(data, 'device_name')),
    'device_lost' => DeviceLostEvent(sequence, _s(data, 'device_fingerprint')),
    'pairing_requested' => PairingRequestedEvent(sequence, _s(data, 'device_fingerprint')),
    'pairing_result' => PairingResultEvent(
        sequence, _s(data, 'device_fingerprint'), _b(data, 'success'),
        data['error'] as String?),
    'transfer_preparing' => TransferPreparingEvent(sequence, _s(data, 'transfer_id')),
    'transfer_preparing_progress' => TransferPreparingProgressEvent(
        sequence, _s(data, 'transfer_id'), _i(data, 'scanned_bytes'), _i(data, 'total_bytes')),
    'transfer_offered' => TransferOfferedEvent(
        sequence, _s(data, 'transfer_id'), _i(data, 'file_count'), _i(data, 'total_bytes')),
    'transfer_progress' => TransferProgressEvent(
        sequence, _s(data, 'transfer_id'), _i(data, 'verified_bytes'), _i(data, 'total_bytes')),
    'transfer_reconnecting' => TransferReconnectingEvent(
        sequence, _s(data, 'transfer_id'), _i(data, 'attempt'), _i(data, 'backoff_ms')),
    'transfer_resumed' => TransferResumedEvent(sequence, _s(data, 'transfer_id')),
    'transfer_paused' =>
        TransferPausedEvent(sequence, _s(data, 'transfer_id'), _s(data, 'reason')),
    'transfer_completed' => TransferCompletedEvent(sequence, _s(data, 'transfer_id')),
    'transfer_cancelled' => TransferCancelledEvent(sequence, _s(data, 'transfer_id')),
    'transfer_failed' => TransferFailedEvent(
        sequence, _s(data, 'transfer_id'), _s(data, 'error_code'), _b(data, 'retryable'),
        _b(data, 'part_kept')),
    'incoming_connection' => IncomingConnectionEvent(sequence, _s(data, 'device_fingerprint')),
    'runtime_config_changed' =>
        RuntimeConfigChangedEvent(sequence, RuntimeConfigDto.fromJson(data)),
    'daemon_stopping' => DaemonStoppingEvent(sequence),
    _ => throw IpcProtocolException('unknown event name: $name'),
  };
}
