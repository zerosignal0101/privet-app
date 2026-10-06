/// Parsing/formatting for the `ip:port` strings exchanged during pairing.
///
/// The pairing-by-address input is a free-text box, so it has to tolerate what
/// a human actually types: a bare IP (port omitted), an IPv4 `ip:port`, a
/// bracketed IPv6 `[addr]:port`, or a bare IPv6 literal. Splitting on `:` is
/// wrong for IPv6 in every one of those cases, so all of it goes through here.
library;

/// The daemon's default QUIC/TCP port, used when an address carries no port.
const int kDefaultPort = 47808;

bool isIpv6Literal(String ip) => ip.contains(':');

/// Renders `ip` + `port` as a dialable string, bracketing IPv6 literals so the
/// result is unambiguous when pasted into a pair-by-address box.
String formatDialString(String ip, int port) =>
    isIpv6Literal(ip) ? '[$ip]:$port' : '$ip:$port';

/// Splits a user-entered address into `(ip, port)`.
///
/// The port is optional: a bare `10.29.210.120` or `fe80::1` gets
/// [defaultPort]. Bracketed IPv6 (`[fe80::1]:47808`) is unwrapped so the IP is
/// passed to the daemon without the brackets. Returns null when [address] is
/// empty or the port suffix is not a number — callers surface that as an input
/// error rather than silently dialing a wrong port.
({String ip, int port})? parseDialString(
  String address, {
  int defaultPort = kDefaultPort,
}) {
  var s = address.trim();
  if (s.isEmpty) return null;

  int port;
  if (s.startsWith('[')) {
    // Bracketed IPv6: [addr] or [addr]:port
    final end = s.indexOf(']');
    if (end < 0) return null;
    final ip = s.substring(1, end);
    final rest = s.substring(end + 1);
    if (ip.isEmpty) return null;
    if (rest.isEmpty) {
      port = defaultPort;
    } else {
      if (!rest.startsWith(':')) return null;
      final parsed = int.tryParse(rest.substring(1));
      if (parsed == null) return null;
      port = parsed;
    }
    return (ip: ip, port: port);
  }

  // Two or more colons means this is a bare IPv6 literal, and a bare IPv6
  // literal carries no port: there is no way to tell a trailing `:47808` from
  // part of the address (`fe80::1:47808` is a perfectly valid literal). Ported
  // IPv6 must be bracketed, which is handled above. One colon means an IPv4
  // `ip:port`, so a non-numeric suffix there is a typo, not an address.
  if (isIpv6Literal(s)) {
    if (':'.allMatches(s).length >= 2) return (ip: s, port: defaultPort);
    return _parseIpv4WithPort(s, defaultPort);
  }

  return _parseIpv4WithPort(s, defaultPort);
}

/// Whether [address] carries a port rather than relying on the default.
///
/// [parseDialString] folds both cases into one `(ip, port)` pair, which is right
/// for dialling but not for `resolve`: an omitted port means "whatever this
/// daemon listens on" — what a peer built the same way answers on — while a
/// typed one is an instruction to use it. Probed with a sentinel rather than
/// re-deriving the bracket/colon rules here, so the two cannot drift apart.
bool hasExplicitPort(String address) {
  final parsed = parseDialString(address, defaultPort: 0);
  return parsed != null && parsed.port != 0;
}

({String ip, int port})? _parseIpv4WithPort(String s, int defaultPort) {
  final colon = s.indexOf(':');
  if (colon < 0) return (ip: s, port: defaultPort);
  final parsed = int.tryParse(s.substring(colon + 1));
  if (parsed == null) return null;
  final ip = s.substring(0, colon);
  if (ip.isEmpty) return null;
  return (ip: ip, port: parsed);
}

// ---- IP-literal validation (for the send-to-address box) --------------------

bool isValidIpv4(String s) {
  final parts = s.split('.');
  if (parts.length != 4) return false;
  for (final p in parts) {
    if (p.isEmpty || p.length > 3) return false;
    // Reject non-digits; `int.tryParse` would also accept a leading '+'/'-'.
    if (!RegExp(r'^\d+$').hasMatch(p)) return false;
    final v = int.parse(p);
    if (v > 255) return false;
    // No leading zeros: "010" is ambiguous (octal in some stacks) and a typo.
    if (p.length > 1 && p.startsWith('0')) return false;
  }
  return true;
}

bool isValidIpv6(String s) {
  if (s.isEmpty || s.contains('%')) return false; // no scope-id / zone here
  // At most one "::" (IPv6 allows the :: compression exactly once).
  final dbl = '::'.allMatches(s).length;
  if (dbl > 1) return false;

  var head = s;
  var tail = '';
  if (dbl == 1) {
    final idx = s.indexOf('::');
    head = s.substring(0, idx);
    tail = s.substring(idx + 2);
  }

  final headParts = head.isEmpty ? <String>[] : head.split(':');
  final tailParts = tail.isEmpty ? <String>[] : tail.split(':');

  // A trailing IPv4-mapped form ("::ffff:192.168.1.1") is legal; it counts as
  // two groups.
  var groupCount = 0;
  for (final parts in [headParts, tailParts]) {
    for (int i = 0; i < parts.length; i++) {
      final p = parts[i];
      if (p.isEmpty) return false;
      final isLastOfPart = i == parts.length - 1;
      if (p.contains('.')) {
        if (!isLastOfPart || !isValidIpv4(p)) return false;
        groupCount += 2;
        continue;
      }
      if (p.length > 4 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(p)) return false;
      groupCount += 1;
    }
  }

  if (dbl == 1) {
    // "::" must stand for at least one omitted group.
    return groupCount < 8;
  }
  return groupCount == 8;
}

/// True when [s] is a bare, well-formed IPv4 or IPv6 literal.
bool isValidIpLiteral(String s) =>
    s.isEmpty ? false : (isIpv6Literal(s) ? isValidIpv6(s) : isValidIpv4(s));

/// The outcome of reading the "send to this address" box.
class ViaAddress {
  const ViaAddress._(this.ip, this.error);

  /// The address is valid; [ip] is the bare IP to hand the engine as `via`.
  const ViaAddress.valid(String ip) : this._(ip, null);

  /// The input could not be used. [error] is user-facing; [ip] is null.
  const ViaAddress.invalid(String error) : this._(null, error);

  final String? ip;
  final String? error;
  bool get isValid => ip != null;
}

/// Normalises the address the user typed into the **bare IP** the engine's
/// `via` field requires.
///
/// The box is deliberately forgiving: a port may be typed (it is stripped and
/// otherwise ignored, because the engine takes the port from the device
/// record), and IPv6 may be bracketed. But unlike [parseDialString] — which
/// only splits, and is fine for pairing where the daemon reports the real
/// failure — this validates the address itself, so an obvious typo is caught
/// here instead of becoming a request the daemon is bound to reject.
///
/// An empty (or whitespace-only) input is valid and means "no override": the
/// engine then dials the address already in the device record, which is the
/// normal case and must not be forced into an explicit address.
ViaAddress parseViaAddress(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return const ViaAddress._(null, null);

  final parsed = parseDialString(trimmed);
  if (parsed == null) {
    return const ViaAddress.invalid(
        'Could not read that address — enter an IP, optionally with a port.');
  }
  if (!isValidIpLiteral(parsed.ip)) {
    return ViaAddress.invalid('"${parsed.ip}" is not a valid IP address.');
  }
  return ViaAddress.valid(parsed.ip);
}
