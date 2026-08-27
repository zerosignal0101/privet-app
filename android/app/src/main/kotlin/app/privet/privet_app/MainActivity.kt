package app.privet.privet_app

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // Byte bridge to the on-device privetd unix socket.
        PrivetIpcChannel().register(messenger)

        // Small platform queries the Dart side needs (CPU ABI for the daemon bundle).
        MethodChannel(messenger, "privet/platform").setMethodCallHandler { call, result ->
            when (call.method) {
                "getAbi" -> {
                    val abi = android.os.Build.SUPPORTED_ABIS.firstOrNull()
                        ?: "arm64-v8a"
                    Log.d("PrivetPlatform", "primary ABI: $abi")
                    result.success(abi)
                }
                else -> result.notImplemented()
            }
        }
    }
}
