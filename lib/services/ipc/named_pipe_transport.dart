import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'transport.dart';

class NamedPipeConnectException implements Exception {
  NamedPipeConnectException(this.pipeName, this.errorCode);
  final String pipeName;
  final int errorCode;
  @override
  String toString() => 'NamedPipeConnectException($pipeName, Win32 error $errorCode)';
}

/// Windows named-pipe client over the win32 package.
///
/// Reading uses PeekNamedPipe + ReadFile from a short timer so the Dart event
/// loop is never blocked on an empty pipe. Writes are synchronous (WriteFile),
/// which is acceptable for local IPC frames.
class NamedPipeTransport implements Transport {
  NamedPipeTransport(this.pipeName);
  final String pipeName;

  @override
  Future<TransportConnection> connect() async {
    final handle = _open();
    final incoming = StreamController<List<int>>();
    final out = StreamController<List<int>>();
    var closed = false;
    Timer? timer;

    Future<void> close() async {
      if (closed) return;
      closed = true;
      timer?.cancel();
      CloseHandle(handle);
      await incoming.close();
      await out.close();
    }

    timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (closed) return;
      final available = _peekAvailable(handle);
      if (available == null) {
        incoming.addError(NamedPipeConnectException(pipeName, GetLastError()));
        timer?.cancel();
        close();
        return;
      }
      if (available == 0) return;
      final chunk = _read(handle, available);
      if (chunk == null) {
        incoming.addError(NamedPipeConnectException(pipeName, GetLastError()));
        timer?.cancel();
        close();
        return;
      }
      incoming.add(chunk);
    });

    out.stream.listen((bytes) {
      _write(handle, bytes);
    }, onError: (_) {}, onDone: () => close());

    return TransportConnection(incoming: incoming.stream, out: out.sink);
  }

  int _open() {
    final name = pipeName.toNativeUtf16();
    final handle = CreateFile(
      name,
      GENERIC_READ | GENERIC_WRITE,
      0, // no sharing
      nullptr, // security attributes
      OPEN_EXISTING,
      0, // flags
      NULL, // template file
    );
    malloc.free(name);
    if (handle == INVALID_HANDLE_VALUE) {
      throw NamedPipeConnectException(pipeName, GetLastError());
    }
    return handle;
  }

  /// Returns the number of bytes available to read, or `null` on error.
  int? _peekAvailable(int handle) {
    final avail = calloc<Uint32>();
    final total = calloc<Uint32>();
    final left = calloc<Uint32>();
    final ok = PeekNamedPipe(handle, nullptr, 0, nullptr, avail, total);
    final result = avail.value; // lpTotalBytesAvail
    calloc.free(avail);
    calloc.free(total);
    calloc.free(left);
    if (ok == 0) return null;
    return result;
  }

  Uint8List? _read(int handle, int count) {
    final buffer = calloc<Uint8>(count);
    final read = calloc<Uint32>();
    final ok = ReadFile(handle, buffer, count, read, nullptr);
    final bytesRead = read.value;
    final bytes = Uint8List(bytesRead);
    if (bytesRead > 0) {
      bytes.setAll(0, buffer.asTypedList(bytesRead));
    }
    calloc.free(buffer);
    calloc.free(read);
    if (ok == 0) return null;
    return bytes;
  }

  void _write(int handle, List<int> bytes) {
    final list = Uint8List.fromList(bytes);
    final buffer = calloc<Uint8>(list.length);
    buffer.asTypedList(list.length).setAll(0, list);
    final written = calloc<Uint32>();
    final ok = WriteFile(handle, buffer, list.length, written, nullptr);
    final bytesWritten = written.value;
    calloc.free(buffer);
    calloc.free(written);
    if (ok == 0) {
      throw NamedPipeConnectException(pipeName, GetLastError());
    }
    assert(bytesWritten == list.length,
        'short pipe write: $bytesWritten of ${list.length}');
  }
}
