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

({String ip, int port})? _parseIpv4WithPort(String s, int defaultPort) {
  final colon = s.indexOf(':');
  if (colon < 0) return (ip: s, port: defaultPort);
  final parsed = int.tryParse(s.substring(colon + 1));
  if (parsed == null) return null;
  final ip = s.substring(0, colon);
  if (ip.isEmpty) return null;
  return (ip: ip, port: parsed);
}
