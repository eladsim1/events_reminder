import 'event.dart';

/// אירוע מהקובץ שדומה לאחד קיים, בלי שאפשר להכריע עליו לבד.
///
/// הדמיון הוא **אותו תאריך בשם אחר**. הצירוף הזה הוא לרוב אותו אירוע
/// שנכתב בשני נוסחים – "אמא" מול "רחל" – ולכן כדאי לשאול עליו. שם זהה
/// בתאריך אחר, לעומת זאת, אינו נחשב דמיון: שני אנשים יכולים לשאת אותו שם,
/// וניחוש על שמות היה מייצר רעש במקום עזרה.
///
/// **שואלים, ולא מכריעים.** בימי הולדת במיוחד: שני אנשים שונים שנולדו
/// באותו יום הם מקרה שכיח לגמרי, ומיזוג אוטומטי היה מוחק אחד מהם.
class MergeCandidate {
  final Event incoming;
  final Event existing;

  const MergeCandidate({required this.incoming, required this.existing});
}

/// מה שייבוא במצב הוספה עומד לעשות, לפני שהוא עושה זאת.
///
/// מופרד מהביצוע כדי שהמסך יוכל לשאול על [candidates] לפני שנוגעים בנתונים.
class MergePlan {
  /// אין להם מקבילה – ייווספו כמות שהם.
  final List<Event> toAdd;

  /// זהים לגמרי לקיימים (שם ותאריך). מדולגים בלי לשאול.
  final int identical;

  /// דומים, וטעונים הכרעה.
  final List<MergeCandidate> candidates;

  const MergePlan({
    required this.toAdd,
    required this.identical,
    required this.candidates,
  });

  bool get needsDecision => candidates.isNotEmpty;
}
