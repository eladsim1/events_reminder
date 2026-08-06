/// סינון הרשימה לפי קרבת **תאריך האזכרה** (לא מועד התזכורת).
///
/// נבחר לפי האזכרה כדי להיות עקבי עם מיון הרשימה, ומפני שזה מה שמשתמש
/// מחפש כשהוא שואל "מה יש לי החודש".
enum MemorialFilter {
  all('הכל', null),
  week('השבוע', 7),
  month('החודש', 30);

  const MemorialFilter(this.label, this.days);

  final String label;

  /// חלון הימים, או null עבור [all].
  final int? days;

  /// הודעה למצב שבו יש אזכרות אך אף אחת אינה בחלון.
  String get emptyMessage => switch (this) {
        MemorialFilter.all => 'אין אזכרות עדיין',
        MemorialFilter.week => 'אין אזכרות בשבוע הקרוב',
        MemorialFilter.month => 'אין אזכרות בחודש הקרוב',
      };
}
