/// סינון הרשימה לפי קרבת **תאריך האירוע** (לא מועד התזכורת).
///
/// נבחר לפי האירוע כדי להיות עקבי עם מיון הרשימה, ומפני שזה מה שמשתמש
/// מחפש כשהוא שואל "מה יש לי החודש".
enum EventFilter {
  all('הכל', null),
  week('השבוע', 7),
  month('החודש', 30);

  const EventFilter(this.label, this.days);

  final String label;

  /// חלון הימים, או null עבור [all].
  final int? days;

  /// הודעה למצב שבו יש אירועים אך אף אחד אינו בחלון.
  String get emptyMessage => switch (this) {
        EventFilter.all => 'אין עדיין אירועים ברשימה',
        EventFilter.week => 'אין אירועים בשבוע הקרוב',
        EventFilter.month => 'אין אירועים בחודש הקרוב',
      };
}
