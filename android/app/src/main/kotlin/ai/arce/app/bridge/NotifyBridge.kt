package ai.arce.app.bridge

import ai.arce.app.MainActivity
import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * Notifications about a reply (it waits for the user, is finished, failed) and the permission to show
 * them, for the Dart side (`ai.arce.app/notify`). Separate from [SystemBridge] because asking for the
 * permission needs the Activity; it is held weakly and let go in [detach].
 */
class NotifyBridge(activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL_ATTENTION = "attention"
        private const val CHANNEL_DONE = "done"
        private const val REQUEST_CODE = 4201
        private const val FIRST_ID = 4200
    }

    private val activityRef = WeakReference(activity)
    private val context: Context = activity.applicationContext
    private val channel = MethodChannel(messenger, "ai.arce.app/notify")
    private var pending: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler(this)
    }

    /**
     * The screen is gone. Showing a notification needs only the application context, so the channel stays
     * (that is when a notification is needed most); asking for the permission needs a screen and is refused.
     */
    fun detach() {
        activityRef.clear()
        pending?.success(false)
        pending = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "allowed" -> result.success(allowed())
                "request" -> request(result)
                "show" -> {
                    show(
                        kind = call.argument<String>("kind").orEmpty(),
                        title = call.argument<String>("title").orEmpty(),
                        body = call.argument<String>("body").orEmpty(),
                        group = call.argument<String>("group").orEmpty(),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            result.error("notify_error", e.message ?: e.javaClass.simpleName, null)
        }
    }

    /** Called by the Activity with the answer to the permission question. */
    fun onPermissionResult(requestCode: Int) {
        if (requestCode != REQUEST_CODE) return
        pending?.success(allowed())
        pending = null
    }

    private fun manager(): NotificationManager = context.getSystemService(NotificationManager::class.java)

    private fun granted(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun allowed(): Boolean = granted() && manager().areNotificationsEnabled()

    private fun request(result: MethodChannel.Result) {
        if (allowed()) {
            result.success(true)
            return
        }
        val activity = activityRef.get()
        if (granted() || activity == null || pending != null) {
            // nothing to ask: the permission is given and the user turned the app's notifications off
            // in the system settings, or there is no screen to ask on
            result.success(false)
            return
        }
        pending = result
        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_CODE)
    }

    private fun show(kind: String, title: String, body: String, group: String) {
        if (!allowed()) return
        // one for what needs the user (it should make a sound), one for what is only news
        val urgent = kind != "done"
        val id = if (urgent) CHANNEL_ATTENTION else CHANNEL_DONE
        manager().createNotificationChannel(
            NotificationChannel(
                id,
                if (urgent) "確認・失敗" else "完了",
                if (urgent) NotificationManager.IMPORTANCE_HIGH else NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = if (urgent) "許可や答えが必要なとき、失敗したとき" else "返信が終わったとき"
            },
        )
        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = Notification.Builder(context, id)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        // the same conversation keeps one notification: the newest replaces the one before it
        manager().notify(FIRST_ID + Math.floorMod(group.hashCode(), 1000), notification)
    }
}
