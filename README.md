# תזכורת אזכרות 🕯

אפליקציית Flutter לניהול אזכרות לפי התאריך העברי. הייחוד: התזכורת נשלחת
**ביום שלישי של השבוע שלפני** השבוע שבו חלה יום האזכרה — כדי שיישאר זמן להתכונן.

האפליקציה עצמאית לחלוטין: ללא שרת וללא צורך באינטרנט. כל הנתונים נשמרים מקומית.

## תכונות

- רשימת אזכרות עם תצוגת יום השנה העברי, המופע הקרוב (לועזי **ועברי כולל שנה**,
  למשל `25/10/2026 · י"ד בחשוון תשפ״ז`), מועד ההתראה ומספר הימים שנותרו.
- התזכורות חוזרות מדי שנה: כל אזכרה מתזמנת 20 שנה קדימה, וכל פתיחה של
  האפליקציה ממלאת את החלון מחדש. האזכרה עצמה נשמרת לתמיד ואינה נמחקת.
- בורר תאריך עברי ייעודי (גלגלי גלילה) — ללא DatePicker לועזי. מונע בחירת תאריך שאינו קיים (למשל ל' באייר).
- תמיכה מלאה בשנים מעוברות: אדר / אדר א' / אדר ב' (כולל שמירת סוג האדר).
- הפעלה/כיבוי התראה לכל אזכרה, עריכה ומחיקה.
- ייצוא/ייבוא נתונים לקובץ JSON.
- Material 3, RTL מלא, עברית, ותמיכה במצב כהה.

## ארכיטקטורה

מבנה שכבות מודולרי; ה-UI אינו ניגש ישירות למסד הנתונים ואינו מבצע חישובי תאריכים.

```
Presentation (screens/ widgets/)
        ↓
State Management (providers/ — Riverpod)
        ↓
Repository (repository/)
        ↓
Services (services/ — HebrewCalendarService, NotificationService)
        ↓
SQLite (database/)
```

עקרונות מפתח:
- כל חישובי התאריכים מרוכזים ב-`HebrewCalendarService` בלבד.
- כל ההתראות מנוהלות ב-`NotificationService` בלבד.
- כל גישה לנתונים עוברת דרך `MemorialRepository`.
- כל פעולה המשנה אזכרה (הוספה/עריכה/מחיקה) מעדכנת את ההתראות המתוזמנות.

## מבנה הפרויקט

```
lib/
  app.dart, main.dart
  models/       memorial.dart, hebrew_date.dart
  repository/   memorial_repository.dart
  database/     database_helper.dart
  services/     notification_service.dart, hebrew_calendar_service.dart
  providers/    memorial_provider.dart
  widgets/      hebrew_date_picker.dart, memorial_card.dart, memorial_form.dart
  screens/      splash_screen.dart, home_screen.dart,
                add_memorial_screen.dart, edit_memorial_screen.dart,
                settings_screen.dart
test/           hebrew_calendar_service_test.dart, memorial_model_test.dart,
                ui_test.dart (רנדור כל המסכים + הנעת הזרימות), goldens/
```

## הרצה

דרושה התקנת Flutter (ערוץ יציב עדכני, ≥ 3.27).

```bash
flutter pub get
flutter run           # על מכשיר/אמולטור אנדרואיד מחובר
flutter test          # הרצת הבדיקות
```

הקובץ `android/local.properties` נוצר אוטומטית על ידי Flutter ומכיל את
נתיב ה-SDK. אם הוא חסר, הרצת `flutter run` פעם אחת תיצור אותו.

## לוגיקת התזכורת

1. חישוב התאריך הלועזי של האזכרה הקרובה (מדלג על שנים שבהן היום/החודש אינם קיימים).
2. מציאת יום ראשון של שבוע האזכרה.
3. חזרה שבוע אחד אחורה.
4. יום שלישי של אותו שבוע — זהו מועד ההתראה, בשעה שנקבעה.

**דוגמה:** אזכרה ביום חמישי 20/05/2027 ⟵ התראה ביום שלישי 11/05/2027.

מועד ההתראה מקדים את האזכרה ב-5 עד 11 יום (תלוי ביום בשבוע שבו חלה האזכרה).
לכן בכל שנה יש חלון שבו יום השלישי כבר חלף אך האזכרה עצמה עוד לפנינו; בחלון
הזה `reminderDate` מחזיר תאריך שעבר, ותזמון ההתראות נעשה דרך
`nextFutureReminderDate` שמגלגל לשנה העברית הבאה.

כל חשבון הימים מתבצע על רכיבי תאריך (או ב-UTC) ולא באמצעות `Duration` — ראה
`CLAUDE.md`.

## הרשאות אנדרואיד

- `POST_NOTIFICATIONS` — הצגת התראות (אנדרואיד 13+).
- `SCHEDULE_EXACT_ALARM` / `USE_EXACT_ALARM` — תזמון מדויק.
- `RECEIVE_BOOT_COMPLETED` — שחזור התראות לאחר הפעלה מחדש של המכשיר.

ההרשאות מתבקשות דרך `flutter_local_notifications` עצמו
(`requestNotificationsPermission` / `requestExactAlarmsPermission`).

## הרחבות עתידיות (לא בגרסה זו)

סנכרון עם Google Drive, ייצוא/ייבוא אוטומטי, מספר תזכורות לאזכרה, חיפוש,
סינון לפי חודש, ווידג'ט למסך הבית, תמיכה ב-iOS ובשפות נוספות, סנכרון בין מכשירים.
