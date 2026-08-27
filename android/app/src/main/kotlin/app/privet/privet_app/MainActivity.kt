package app.privet.privet_app

import android.content.Intent
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private lateinit var fileChannel: PrivetFileChannel
    private lateinit var shareChannel: PrivetShareChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // Byte bridge to the on-device privetd unix socket.
        PrivetIpcChannel().register(messenger)

        // SAF content-URI operations for send/receive paths (directory picker
        // results are forwarded via onActivityResult below).
        fileChannel = PrivetFileChannel(this)
        fileChannel.register(messenger)

        // ACTION_SEND payloads. A cold-start share intent is processed after
        // registration so the stashed args survive until Dart pulls them.
        shareChannel = PrivetShareChannel(this)
        shareChannel.register(messenger)
        if (intent.action?.startsWith("android.intent.action.SEND") == true) {
            shareChannel.handleShareIntent(intent)
        }

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

        // Promotes the daemon process to a foreground service (startForeground
        // with type dataSync) once the Dart side confirms privetd is running.
        MethodChannel(messenger, "privet/daemon_service").setMethodCallHandler { call, result ->
            if (call.method == "start") {
                val intent = Intent(this, PrivetDaemonService::class.java)
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                    startForegroundService(intent)
                } else {
                    startService(intent)
                }
                result.success(null)
            } else result.notImplemented()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (::fileChannel.isInitialized) {
            fileChannel.onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // A new share while the app is already running: cache the URIs and push
        // them to Dart (the listener opens the send preparation page).
        if (::shareChannel.isInitialized &&
            intent.action?.startsWith("android.intent.action.SEND") == true
        ) {
            shareChannel.handleShareIntent(intent)
            shareChannel.pushPendingShare()
        }
    }
}
