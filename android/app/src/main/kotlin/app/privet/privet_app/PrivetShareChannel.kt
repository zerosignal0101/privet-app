package app.privet.privet_app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicLong

/**
 * ACTION_SEND / ACTION_SEND_MULTIPLE handling: caches shared content URIs to
 * the send-cache (the daemon only reads real paths) and forwards the cached
 * paths (or plain text) to Flutter.
 *
 * MethodChannel 'privet/share':
 *   - getPendingShare -> `{paths, text}` (cold-start pull; consumed once)
 *   - onShare (push)  -> `{paths, text}` (app already running / onNewIntent)
 */
class PrivetShareChannel(private val activity: Activity) {
    companion object {
        private const val CHANNEL = "privet/share"
        private val session = AtomicLong(System.currentTimeMillis())
    }

    private var pendingShareArgs: Map<String, Any?>? = null
    private var shareChannel: MethodChannel? = null

    fun register(messenger: BinaryMessenger) {
        shareChannel = MethodChannel(messenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPendingShare" -> {
                        result.success(pendingShareArgs)
                        pendingShareArgs = null // consumed
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /// Process a share intent (cold start via getIntent() in configureFlutterEngine,
    /// or onNewIntent) and stash the args for a later getPendingShare / onShare.
    fun handleShareIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action ?: return
        val paths = mutableListOf<String>()
        var text: String? = null
        try {
            when (action) {
                Intent.ACTION_SEND -> {
                    if (intent.type?.startsWith("text/") == true) {
                        text = intent.getStringExtra(Intent.EXTRA_TEXT)
                    } else {
                        val uri = shareUri(intent)
                        if (uri != null) copyFileToCache(uri)?.let { paths.add(it) }
                    }
                }
                Intent.ACTION_SEND_MULTIPLE -> {
                    val uris = shareUris(intent)
                    uris?.forEach { copyFileToCache(it)?.let { paths.add(it) } }
                }
            }
        } catch (e: Exception) {
            Log.e("PrivetShare", "handleShareIntent error", e)
        }
        if (paths.isEmpty() && (text == null || text.isBlank())) return
        val args = mutableMapOf<String, Any?>()
        if (paths.isNotEmpty()) args["paths"] = paths
        if (text != null) args["text"] = text
        pendingShareArgs = args
    }

    /// Push a pending share to Dart (used after onNewIntent when the engine is live).
    fun pushPendingShare() {
        pendingShareArgs?.let { args ->
            activity.runOnUiThread {
                shareChannel?.invokeMethod("onShare", args)
            }
        }
    }

    private fun shareUri(intent: Intent): Uri? =
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }

    private fun shareUris(intent: Intent): ArrayList<Uri>? =
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
        }

    private fun copyFileToCache(uri: Uri): String? {
        return try {
            val name = fileName(uri.toString()) ?: "shared_${System.currentTimeMillis()}"
            val dir = File(activity.cacheDir, "privet/send-cache/${session.incrementAndGet()}")
            dir.mkdirs()
            val out = File(dir, name)
            activity.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(out).use { o -> input.copyTo(o) }
            }
            out.absolutePath
        } catch (e: Exception) {
            Log.w("PrivetShare", "copyFileToCache failed for $uri", e)
            null
        }
    }

    private fun fileName(uri: String): String? {
        return try {
            val cursor = activity.contentResolver.query(Uri.parse(uri), null, null, null, null)
            cursor?.use {
                if (it.moveToFirst()) {
                    val idx = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) return it.getString(idx)
                }
            }
            Uri.parse(uri).lastPathSegment
        } catch (_: Exception) {
            Uri.parse(uri).lastPathSegment
        }
    }
}
