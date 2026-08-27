import 'dart:io';

/// Locates a built `privetd` binary, preferring the sibling privet repo's
/// debug build. Returns `null` when none is available so the integration test
/// can skip. Override the repo location with the `PRIVET_REPO` env var.
String? findPrivetd() {
  final repo = Platform.environment['PRIVET_REPO'] ?? r'D:\C-Codes\privet';
  final exe = Platform.isWindows ? 'privetd.exe' : 'privetd';
  for (final profile in const ['debug', 'release']) {
    final path = '$repo/target/$profile/$exe';
    if (File(path).existsSync()) return path;
  }
  return null;
}
