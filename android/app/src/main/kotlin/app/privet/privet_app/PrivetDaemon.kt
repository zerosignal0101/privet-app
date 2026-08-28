package app.privet.privet_app

import android.content.Context
import android.os.Build
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * JNI entry points into `libprivetd_embed.so` (see privet-daemon's
 * android_bridge.rs). Symbol names follow the JNI convention for this class,
 * so `@JvmStatic external fun`s bind to the exported symbols at load time.
 */
object PrivetDaemonNative {
    init {
        System.loadLibrary("privetd_embed")
    }

    @JvmStatic external fun privetdRun(configPath: String, ipcPath: String): Int

    @JvmStatic external fun privetdShutdown()
}

/**
 * Owns the thread that runs the embedded privetd to completion. On Android the
 * daemon can no longer be exec'd from app-private storage (SELinux W^X), so it
 * runs in-process; the foreground service keeps the process (and therefore this
 * thread and the unix socket) alive while the app is backgrounded.
 */
object PrivetDaemon {
    private val started = AtomicBoolean(false)

    /** Starts the daemon thread once; no-ops while it is already running. */
    fun start(configPath: String, ipcPath: String) {
        if (!started.compareAndSet(false, true)) return
        Thread {
            try {
                PrivetDaemonNative.privetdRun(configPath, ipcPath)
            } catch (t: Throwable) {
                Log.e(TAG, "embedded privetd thread failed", t)
            } finally {
                started.set(false)
            }
        }.apply {
            name = "privetd"
            start()
        }
    }

    /** Asks the daemon to shut down cleanly; the thread returns shortly after. */
    fun stop() {
        try {
            PrivetDaemonNative.privetdShutdown()
        } catch (t: Throwable) {
            Log.w(TAG, "privetd shutdown signal failed", t)
        }
    }

    /**
     * Writes the daemon config if it does not exist yet. Mirrors Dart's
     * `encodeDaemonConfig` (daemon_config.dart) so the service can bring the
     * daemon back up on a START_STICKY restart without the UI having run.
     */
    fun ensureConfig(context: Context, configPath: String, socketPath: String) {
        val file = File(configPath)
        if (file.exists()) return
        file.parentFile?.mkdirs()
        val dataDir = File(context.filesDir, "privet/data").path
        // Default save dir must match Dart's `AndroidDaemonBundle.saveDir`
        // (path_provider's getExternalStorageDirectory() -> getExternalFilesDir),
        // not the public storage root: the daemon can't create /storage/emulated/0.
        val saveDir = File(context.getExternalFilesDir(null) ?: context.filesDir, "Privet").path
        val deviceName = "${Build.MANUFACTURER} ${Build.MODEL}".trim()
            .ifEmpty { "privet-device" }
        val config = JSONObject()
            .put("device_name", deviceName)
            .put("data_dir", dataDir)
            .put("save_dir", saveDir)
            .put("ipc_endpoint", socketPath)
            .put("quic_port", 47808)
            .put("tcp_port", 47808)
            .put("discovery_port", 47809) // UDP; must differ from QUIC's UDP 47808
        file.writeText(config.toString())
    }

    private const val TAG = "PrivetDaemon"
}
