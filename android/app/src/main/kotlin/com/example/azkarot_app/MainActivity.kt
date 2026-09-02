package com.example.azkarot_app

import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * ערוץ קטן לבדיקת הפטור מאופטימיזציית סוללה ולבקשתו.
 *
 * נכתב ידנית ולא דרך תוסף בכוונה: מערך הבנייה כאן צר (AGP 8.13.2, Kotlin
 * 2.1.20) ותוסף נוסף הוא סיכון לבנייה כולה, בעוד שכל מה שצריך הוא שתי
 * קריאות מערכת.
 *
 * מה זה כן פותר: אפליקציה פטורה אינה נעצרת בידי אנדרואיד, והאזעקות שלה
 * שורדות. מה שזה **לא** פותר: רשימת "אפליקציות ישנות" של סמסונג מנוהלת
 * בנפרד ואין ממשק לצאת ממנה. הפטור מקטין את הסיכוי להיכנס אליה, ולא מאפס.
 */
class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL = "azkarot_app/battery"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isExempt" -> result.success(isExempt())
                    "requestExemption" -> {
                        requestExemption()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

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
}
