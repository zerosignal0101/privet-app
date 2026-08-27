package app.privet.privet_app

import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Dumb byte bridge to the on-device privetd unix socket. No protocol logic.
 *
 * MethodChannel 'privet/ipc': open(path), write(data), close()
 * EventChannel 'privet/ipc/events': byte chunks (ByteArray -> Uint8List in Dart)
 *
 * Dart assembles the framing (see IpcFrameCodec); this class only moves bytes
 * between the Dart side and the LocalSocket, logging to logcat so `flutter run`
 * keeps a single console.
 */
class PrivetIpcChannel {
    private val main = Handler(Looper.getMainLooper())
    private var socket: LocalSocket? = null
    private var readerThread: Thread? = null
    private var events: EventChannel.EventSink? = null

    fun register(binaryMessenger: io.flutter.plugin.common.BinaryMessenger) {
        MethodChannel(binaryMessenger, "privet/ipc").setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> open(call.argument<String>("path"), result)
                "write" -> write(call.argument<ByteArray>("data"), result)
                "close" -> {
                    close()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(binaryMessenger, "privet/ipc/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    this@PrivetIpcChannel.events = events
                }

                override fun onCancel(arguments: Any?) {
                    events = null
                }
            })
    }

    private fun open(path: String?, result: MethodChannel.Result) {
        if (path == null) {
            result.error("invalid_request", "path required", null)
            return
        }
        close() // idempotent: replace any previous connection
        try {
            val s = LocalSocket()
            s.connect(LocalSocketAddress(path, LocalSocketAddress.Namespace.FILESYSTEM))
            socket = s
            readerThread = Thread { readLoop(s) }.apply {
                isDaemon = true
                name = "privet-ipc-reader"
                start()
            }
            Log.d("PrivetIpc", "opened socket $path")
            result.success(null)
        } catch (e: Exception) {
            Log.e("PrivetIpc", "open failed", e)
            result.error("io", e.message, null)
        }
    }

    private fun write(data: ByteArray?, result: MethodChannel.Result) {
        try {
            val s = socket ?: throw IllegalStateException("socket not open")
            s.outputStream.write(data ?: ByteArray(0))
            s.outputStream.flush()
            result.success(null)
        } catch (e: Exception) {
            Log.e("PrivetIpc", "write failed", e)
            result.error("io", e.message, null)
        }
    }

    private fun readLoop(s: LocalSocket) {
        val buf = ByteArray(64 * 1024)
        try {
            while (true) {
                val n = s.inputStream.read(buf)
                if (n <= 0) break
                val chunk = buf.copyOf(n)
                main.post { events?.success(chunk) }
            }
        } catch (e: Exception) {
            if (!Thread.currentThread().isInterrupted) {
                Log.d("PrivetIpc", "read loop ended: ${e.message}")
            }
        } finally {
            main.post { events?.endOfStream() }
        }
    }

    private fun close() {
        readerThread?.interrupt()
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        socket = null
        readerThread = null
    }
}
