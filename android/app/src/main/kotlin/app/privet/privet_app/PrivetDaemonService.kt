package app.privet.privet_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import java.io.File

/**
 * Pins the app process so the on-device privetd (a thread in this process)
 * survives UI backgrounding. A START_STICKY restart brings the daemon thread
 * back up in [onCreate] without needing the UI, using the same config the Dart
 * side writes.
 *
 * Also holds a [WifiManager.MulticastLock] so mDNS responses aren't filtered by
 * the Wi-Fi driver while the daemon runs — the UDP broadcast beacon works
 * without it, but multicast is a secondary discovery path.
 */
class PrivetDaemonService : Service() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        try {
            val wifi = getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("privet-discovery").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            Log.w("PrivetService", "multicast lock unavailable", e)
        }
        startDaemon()
    }

    private fun startDaemon() {
        val privetDir = File(filesDir, "privet")
        val socketPath = File(privetDir, "privet.sock").path
        val configPath = File(privetDir, "config.json").path
        PrivetDaemon.ensureConfig(this, configPath, socketPath)
        PrivetDaemon.start(configPath, socketPath)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        createChannel(nm)
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            multicastLock?.release()
        } catch (_: Exception) {
        }
        multicastLock = null
    }

    private fun createChannel(nm: NotificationManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Privet daemon",
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }
    }

    private fun buildNotification(): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Privet")
            .setContentText("Transfer daemon running")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

    companion object {
        private const val CHANNEL_ID = "privet-daemon"
        private const val NOTIFICATION_ID = 1
    }
}
