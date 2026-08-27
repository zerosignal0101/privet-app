/// Shorten a device fingerprint for display, e.g. `3f9e10d…`.
String shortFingerprint(String fp) =>
    fp.length > 16 ? '${fp.substring(0, 16)}…' : fp;
