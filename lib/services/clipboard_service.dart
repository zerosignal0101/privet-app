import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

/// Clipboard helpers for the send-preparation flow: pasting file paths copied
/// from a file manager (Windows CF_HDROP / Linux text/uri-list) and saving
/// clipboard text to a real file the daemon can read. Image content is not
/// handled here (deferred — the desktop app focuses on file + text transfer).
class ClipboardService {
  /// Read file paths from the clipboard (files copied via file manager
  /// Ctrl+C). Returns `null` when no file paths are present.
  static Future<List<String>?> readFilePaths() async {
    if (Platform.isWindows) return _readFileListFromClipboard();
    if (Platform.isLinux) return _linuxReadFilePaths();
    return null;
  }

  /// Clipboard text, or null when empty.
  static Future<String?> readText() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    return (text != null && text.trim().isNotEmpty) ? text : null;
  }

  /// Save clipboard text to a unique `.txt` under [dir]. Returns the absolute
  /// path, relative path and size, or null when the clipboard has no text.
  static Future<({String absolutePath, String relativePath, int size})?>
      saveToFile(String dir) async {
    final text = await readText();
    if (text == null) return null;
    final name = textFilename(text);
    final (path: filePath, relativePath: relPath) = uniqueFile(dir, '$name.txt');
    final file = File(filePath);
    await file.writeAsString(text);
    return (
      absolutePath: file.path,
      relativePath: relPath,
      size: await file.length(),
    );
  }

  /// A unique path under [dir] by appending ` (n)` when [fileName] collides.
  /// e.g. `"hello.txt"` → `"hello.txt"` (if absent) or `"hello (1).txt"`.
  static ({String path, String relativePath}) uniqueFile(
      String dir, String fileName) {
    final file = File('$dir/$fileName');
    if (!file.existsSync()) {
      return (path: file.path, relativePath: fileName);
    }
    final dot = fileName.lastIndexOf('.');
    final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot) : '';
    for (int i = 1; i <= 999; i++) {
      final candidate = '$stem ($i)$ext';
      if (!File('$dir/$candidate').existsSync()) {
        return (path: '$dir/$candidate', relativePath: candidate);
      }
    }
    return (path: file.path, relativePath: fileName); // fallback, overwrites
  }

  /// Derive a filename from the first ~24 usable characters of [text].
  static String textFilename(String text) {
    final cleaned = text
        .replaceAll(RegExp(r'[\s\n\r]+'), '_')
        .replaceAll(RegExp(r'[^\w\-_.()]'), '');
    if (cleaned.length <= 24) return cleaned.isEmpty ? 'clipboard' : cleaned;
    return cleaned.substring(0, 24);
  }
}

// ---------------------------------------------------------------------------
// Linux clipboard helpers (xclip / wl-paste)
// ---------------------------------------------------------------------------

/// Detect the Linux desktop session type: `'x11'`, `'wayland'`, or null.
String? _linuxSessionType() {
  final session = Platform.environment['XDG_SESSION_TYPE'];
  if (session == 'x11' || session == 'wayland') return session;
  return null;
}

/// Run [command] with [args] and return stdout as bytes, or null on failure.
Future<Uint8List?> _runClipboardTool(
  String command,
  List<String> args,
  String label,
) async {
  try {
    final result = await Process.run(
      command, args,
      stdoutEncoding: null,
    ).timeout(const Duration(seconds: 2));
    if (result.exitCode == 0 && (result.stdout as List<int>).isNotEmpty) {
      return Uint8List.fromList(result.stdout as List<int>);
    }
    if (kDebugMode) {
      debugPrint('[clipboard] $label $command exited=${result.exitCode}');
    }
  } catch (e) {
    if (kDebugMode) debugPrint('[clipboard] $label $command failed: $e');
  }
  return null;
}

/// Read raw clipboard data in the given [target] format on Linux.
Future<Uint8List?> _linuxReadClipboardData(String target) async {
  final session = _linuxSessionType();
  if (session == 'x11' || session == null) {
    final data = await _runClipboardTool(
      'xclip', ['-selection', 'clipboard', '-t', target, '-o'], 'xclip');
    if (data != null) return data;
  }
  if (session == 'wayland' || session == null) {
    final data = await _runClipboardTool('wl-paste', ['-t', target], 'wl-paste');
    if (data != null) return data;
  }
  return null;
}

/// Parse `text/uri-list` clipboard content into local file paths.
Future<List<String>?> _linuxReadFilePaths() async {
  final raw = await _linuxReadClipboardData('text/uri-list');
  if (raw == null) return null;
  final text = String.fromCharCodes(raw);
  final paths = <String>[];
  for (final line in text.split(RegExp(r'[\r\n]+'))) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    if (trimmed.startsWith('file://')) {
      try {
        final uri = Uri.parse(trimmed);
        if (uri.scheme == 'file') paths.add(uri.toFilePath());
      } catch (_) {}
    }
  }
  return paths.isNotEmpty ? paths : null;
}

// ---------------------------------------------------------------------------
// Windows clipboard (win32)
// ---------------------------------------------------------------------------

/// Read file paths from the Windows CF_HDROP clipboard format.
/// Returns null when no file paths are available.
List<String>? _readFileListFromClipboard() {
  if (OpenClipboard(NULL) == 0) return null;
  try {
    if (IsClipboardFormatAvailable(CF_HDROP) == 0) return null;

    final hglobal = GetClipboardData(CF_HDROP);
    if (hglobal == 0) return null;
    final hmem = Pointer.fromAddress(hglobal);

    final locked = GlobalLock(hmem);
    if (locked == nullptr) return null;

    try {
      final size = GlobalSize(hmem);
      if (size < 20) return null; // at least the DROPFILES header

      final raw = locked.cast<Uint8>().asTypedList(size);

      // DROPFILES layout (all offsets from the start of the struct):
      //   0: pFiles (Uint32) — offset to the file list
      //  12: fNC     (Int32)
      //  16: fWide   (Int32) — non-zero = UTF-16 file names
      final buf = raw.buffer;
      final pFiles = ByteData.view(buf, 0, 4).getUint32(0, Endian.little);
      final fWide = ByteData.view(buf, 16, 4).getUint32(0, Endian.little);

      if (pFiles < 20 || pFiles >= size) return null;

      final paths = <String>[];
      int off = pFiles;
      if (fWide != 0) {
        // UTF-16LE null-terminated strings, double-null terminated.
        while (off + 2 <= size) {
          final codeUnits = <int>[];
          while (off + 2 <= size) {
            final cu = raw[off] | (raw[off + 1] << 8);
            off += 2;
            if (cu == 0) break;
            codeUnits.add(cu);
          }
          if (codeUnits.isEmpty) break; // double null = end of list
          paths.add(String.fromCharCodes(codeUnits));
        }
      } else {
        // ANSI (single-byte) null-terminated strings.
        while (off < size) {
          final bytes = <int>[];
          while (off < size && raw[off] != 0) {
            bytes.add(raw[off]);
            off++;
          }
          off++;
          if (bytes.isEmpty) break;
          paths.add(String.fromCharCodes(bytes));
        }
      }

      return paths.isNotEmpty ? paths : null;
    } finally {
      GlobalUnlock(hmem);
    }
  } finally {
    CloseClipboard();
  }
}
