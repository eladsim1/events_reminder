import 'memorial.dart';

/// אזכרה מהקובץ שדומה לאחת קיימת, בלי שאפשר להכריע עליה לבד.
///
/// הדמיון הוא **אותו תאריך עברי בשם אחר**. התאריך מדויק ואינו נוטה
/// להתנגש במקרה, ולכן הצירוף הזה הוא כמעט תמיד אותו אדם שנכתב בשני
/// נוסחים – "סבא יעקב" מול "יעקב כהן". שם זהה בתאריך אחר, לעומת זאת,
/// אינו נחשב דמיון: שני אנשים יכולים לשאת אותו שם, וניחוש שם היה מייצר
/// רעש במקום עזרה.
class MergeCandidate {
  final Memorial incoming;
  final Memorial existing;

  const MergeCandidate({required this.incoming, required this.existing});
}

/// מה שייבוא במצב הוספה עומד לעשות, לפני שהוא עושה זאת.
///
/// מופרד מהביצוע כדי שהמסך יוכל לשאול על [candidates] לפני שנוגעים בנתונים.
class MergePlan {
  /// אין להן מקבילה – ייווספו כמות שהן.
  final List<Memorial> toAdd;

  /// זהות לגמרי לקיימות (שם ותאריך). מדולגות בלי לשאול.
  final int identical;

  /// דומות, וטעונות הכרעה.
  final List<MergeCandidate> candidates;

  const MergePlan({
    required this.toAdd,
    required this.identical,
    required this.candidates,
  });

  bool get needsDecision => candidates.isNotEmpty;
}
