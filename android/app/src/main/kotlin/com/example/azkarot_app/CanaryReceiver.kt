package com.example.azkarot_app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * אזעקת ביקורת: אזעקה יומית שכל תפקידה הוא לרשום שהיא נורתה.
 *
 * **למה.** כל שאר הבדיקות באפליקציה בוחנות את הספרים שלה – כמה התראות היא
 * חושבת שמתוזמנות. אף אחת מהן אינה רואה את הדבר החשוב באמת: האם אנדרואיד
 * בכלל מפעיל את האזעקות שלנו. מנהל סוללה שמדכא אותן נראה בדיוק כמו מצב
 * תקין, עד שמפספסים אזכרה.
 *
 * המקלט אינו מציג דבר. הוא כותב חותמת זמן ומזמן את עצמו ליום הבא, וכך
 * חותמת שמתיישנת היא הסימן שאזעקות אינן פועלות – **לפני** שאובדת תזכורת
 * ולא אחריה.
 *
 * מה זה מוכיח: שמנגנון האזעקות פועל. מה שזה **אינו** מוכיח: שהתראה הוצגה.
 * המקלט אינו מציג התראה, בכוונה – בדיקה יומית שמייצרת רעש יומי במגירה היא
 * גרועה מהבעיה.
 */
class CanaryReceiver : BroadcastReceiver() {
    companion object {
        const val PREFS = "azkarot_canary"
        const val KEY_LAST_FIRED = "last_fired"

        private const val REQUEST_CODE = 730_001
        private const val INTERVAL_MS = 24L * 60 * 60 * 1000

        /** מזמן את הביקורת הבאה. בטוח לקריאה חוזרת – אותו PendingIntent. */
        fun arm(context: Context) {
            val alarms = context.getSystemService(Context.ALARM_SERVICE)
                as? AlarmManager ?: return
            val at = System.currentTimeMillis() + INTERVAL_MS

            runCatching {
                // לא exact: אין שום חשיבות לדיוק כאן, והביקורת לא אמורה
                // לצרוך מהמכסה של אזעקות מדויקות. allowWhileIdle כדי שהיא
                // תפעל גם ב-Doze – שם בדיוק מעניין לדעת אם היא פועלת.
                alarms.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    at,
                    pendingIntent(context),
                )
            }
        }

        fun lastFired(context: Context): Long =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getLong(KEY_LAST_FIRED, 0L)

        private fun pendingIntent(context: Context): PendingIntent {
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                flags = flags or PendingIntent.FLAG_IMMUTABLE
            }
            return PendingIntent.getBroadcast(
                context,
                REQUEST_CODE,
                Intent(context, CanaryReceiver::class.java),
                flags,
            )
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putLong(KEY_LAST_FIRED, System.currentTimeMillis())
            .apply()

        // מזמנת את עצמה מחדש. אזעקה חד-פעמית לא חוזרת מעצמה, ואילו הסתמכות
        // על פתיחת האפליקציה הייתה הופכת את הבדיקה לחסרת ערך: היא נועדה
        // לפעול דווקא כשלא פותחים אותה.
        arm(context)
    }
}
