package com.example.azkarot_app

import android.app.NotificationManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * ערוץ קטן לבדיקות שאין להן מענה בצד Dart.
 *
 * נכתב ידנית ולא דרך תוסף בכוונה: מערך הבנייה כאן צר (AGP 8.13.2, Kotlin
 * 2.1.20) ותוסף נוסף הוא סיכון לבנייה כולה, בעוד שכל מה שצריך הוא כמה
 * קריאות מערכת.
 */
class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL = "azkarot_app/checks"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "batteryExempt" -> result.success(isExempt())
                    "requestBatteryExemption" -> {
                        requestExemption()
                        result.success(null)
                    }
                    "channelEnabled" ->
                        result.success(isChannelEnabled(call.arguments as? String))
                    "hasNotificationIcon" -> result.success(hasNotificationIcon())
                    "armCanary" -> {
                        CanaryReceiver.arm(applicationContext)
                        result.success(null)
                    }
                    "canaryLastFired" ->
                        result.success(CanaryReceiver.lastFired(applicationContext))
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * אפליקציה שאנדרואיד רשאי לעצור מאבדת גם את **האזעקות הרשומות שלה**,
     * כולל כאלה שתוזמנו מזמן.
     *
     * מה שזה לא פותר: רשימת "אפליקציות ישנות" של סמסונג מנוהלת בנפרד ואין
     * ממשק לצאת ממנה. הפטור מקטין את הסיכוי להיכנס אליה, ולא מאפס.
     */
    private fun isExempt(): Boolean {
        val power = getSystemService(POWER_SERVICE) as? PowerManager
            ?: return true
        return power.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestExemption() {
        // הדיאלוג הישיר דורש את ההרשאה REQUEST_IGNORE_BATTERY_OPTIMIZATIONS.
        // בחלק מהמכשירים הוא חסום או חסר, ולכן יש נפילה חזרה לרשימה
        // בהגדרות – עדיף מסך שצריך לגלול בו על כלום.
        val direct = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:$packageName"),
        )
        val fallback = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)

        val intent = if (direct.resolveActivity(packageManager) != null) {
            direct
        } else {
            fallback
        }
        runCatching { startActivity(intent) }
    }

    /**
     * חסימה של הערוץ בלבד היא כשל מוחלט ושקט לחלוטין.
     *
     * areNotificationsEnabled בודקת ברמת האפליקציה, ולכן ערוץ חסום עובר בה
     * בשלום: המשתמש רואה מצב תקין ושום תזכורת אינה מגיעה לעולם.
     */
    private fun isChannelEnabled(channelId: String?): Boolean {
        if (channelId == null) return true
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true

        val manager = getSystemService(NotificationManager::class.java)
            ?: return true
        // ערוץ שטרם נוצר אינו חסום – הוא ייווצר באתחול הפלאגין.
        val channel = manager.getNotificationChannel(channelId) ?: return true
        return channel.importance != NotificationManager.IMPORTANCE_NONE
    }

    /**
     * האייקון מוגדר כמחרוזת ב-Dart, ולכן מכווץ המשאבים אינו רואה אליו שום
     * הפניה. זה כבר קרה כאן פעם: האייקון נמחק מגרסת release וכל התראה
     * נכשלה בשקט בזמן הירי. keep.xml מגן על זה, וזו בדיקה שנייה על המכשיר
     * עצמו במקום רק בזמן הבנייה.
     */
    private fun hasNotificationIcon(): Boolean =
        resources.getIdentifier("ic_notification", "drawable", packageName) != 0
}
