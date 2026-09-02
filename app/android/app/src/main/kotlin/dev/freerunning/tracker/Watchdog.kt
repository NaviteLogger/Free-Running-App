package dev.freerunning.tracker

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

/**
 * Notices when recording has silently stopped, and says so.
 *
 * The device benchmark for this phone is the whole reason this exists: with a
 * foreground service and a wake lock, in-process work still only ran 27% of the
 * time unconfigured and 73% configured — but AlarmManager alarms fired 100% of
 * the time in both states. Alarms are the one mechanism OxygenOS leaves alone,
 * so they are the only thing that can reliably observe a recording that has
 * been frozen or killed.
 *
 * What this does NOT do is restart recording by itself. The location stream is
 * owned by the Dart isolate, so if the process is gone there is nothing here to
 * restart — reviving it would mean moving capture into a native foreground
 * service, which is a larger change kept in reserve. What this does instead is
 * turn a silent loss into a notification, and the app's existing resume flow
 * picks the session back up with everything recorded so far intact.
 */
object Watchdog {
    private const val PREFS = "watchdog"
    private const val KEY_ACTIVE = "recording_active"
    private const val KEY_HEARTBEAT = "heartbeat_ms"
    private const val CHANNEL_ID = "watchdog"
    private const val NOTIFICATION_ID = 7301

    /**
     * How often to look, and how stale a heartbeat has to be before we complain.
     *
     * `setAndAllowWhileIdle` is used rather than the exact variant because the
     * exact one needs SCHEDULE_EXACT_ALARM, which is a user-facing grant on
     * Android 13+ and one more thing to lose. The inexact variant still fires
     * during Doze; Android just reserves the right to delay it, and clamps
     * repeats to roughly nine minutes. For noticing a dead recorder that is
     * ample, and it costs no permission.
     */
    private const val CHECK_INTERVAL_MS = 5 * 60 * 1000L
    private const val STALE_AFTER_MS = 4 * 60 * 1000L

    fun start(context: Context) {
        prefs(context).edit()
            .putBoolean(KEY_ACTIVE, true)
            .putLong(KEY_HEARTBEAT, System.currentTimeMillis())
            .apply()
        schedule(context)
    }

    fun heartbeat(context: Context) {
        prefs(context).edit()
            .putLong(KEY_HEARTBEAT, System.currentTimeMillis())
            .apply()
    }

    fun stop(context: Context) {
        prefs(context).edit().putBoolean(KEY_ACTIVE, false).apply()
        alarmManager(context).cancel(pendingIntent(context))
        notificationManager(context).cancel(NOTIFICATION_ID)
    }

    fun schedule(context: Context) {
        alarmManager(context).setAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            System.currentTimeMillis() + CHECK_INTERVAL_MS,
            pendingIntent(context),
        )
    }

    /** Returns true if a recording session has gone quiet. */
    fun isStalled(context: Context): Boolean {
        val p = prefs(context)
        if (!p.getBoolean(KEY_ACTIVE, false)) return false
        val last = p.getLong(KEY_HEARTBEAT, 0L)
        return last > 0L && System.currentTimeMillis() - last > STALE_AFTER_MS
    }

    fun isActive(context: Context): Boolean =
        prefs(context).getBoolean(KEY_ACTIVE, false)

    fun warn(context: Context) {
        val manager = notificationManager(context)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Recording stopped",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Warns when a run stops recording unexpectedly"
                },
            )
        }

        val launch = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }

        val tap = PendingIntent.getActivity(
            context,
            0,
            launch ?: Intent(),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        manager.notify(
            NOTIFICATION_ID,
            NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_alert)
                .setContentTitle("Recording stopped")
                .setContentText("The system suspended the run. Tap to resume it.")
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_ERROR)
                .setContentIntent(tap)
                .setAutoCancel(true)
                .build(),
        )
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun alarmManager(context: Context) =
        context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

    private fun notificationManager(context: Context) =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun pendingIntent(context: Context) = PendingIntent.getBroadcast(
        context,
        0,
        Intent(context, WatchdogReceiver::class.java),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}

class WatchdogReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!Watchdog.isActive(context)) return
        if (Watchdog.isStalled(context)) {
            Watchdog.warn(context)
        }
        // setAndAllowWhileIdle is one-shot, so each firing arms the next.
        Watchdog.schedule(context)
    }
}
