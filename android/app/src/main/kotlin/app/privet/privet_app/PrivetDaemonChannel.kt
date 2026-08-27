package app.privet.privet_app

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Starts/stops the in-process daemon from Dart over the `privet/daemon`
 * channel. Idempotent: the foreground service also starts the daemon in its
 * onCreate, so these calls only matter for the very first launch (when the
 * service is promoted only after the daemon is confirmed reachable).
 */
class PrivetDaemonChannel {
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "privet/daemon").setMethodCallHandler(::onMethodCall)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val configPath = call.argument<String>("configPath")
                val ipcPath = call.argument<String>("ipcPath")
                if (configPath == null || ipcPath == null) {
                    result.error("bad_args", "configPath and ipcPath are required", null)
                    return
                }
                PrivetDaemon.start(configPath, ipcPath)
                result.success(null)
            }
            "stop" -> {
                PrivetDaemon.stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
