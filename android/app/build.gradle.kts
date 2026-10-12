plugins {
    id("com.android.application")
    id("kotlin-android")
    // Flutter Gradle Plugin חייב לבוא אחרי פלאגיני Android ו-Kotlin.
    id("dev.flutter.flutter-gradle-plugin")
}

/** כל ה-ABI שאנדרואיד מכיר, כדי שאפשר יהיה לחסר מהם. */
val ALL_ABIS = listOf("armeabi-v7a", "arm64-v8a", "x86", "x86_64")

/**
 * אילו ABI נארזים. ברירת המחדל היא שתי ארכיטקטורות ה-ARM, כלומר גם 32
 * וגם 64 סיביות – קובץ אחד שמתקין על כל טלפון.
 *
 * ניתן לצמצום לבנייה קטנה יותר, לטלפון שהאחסון בו צפוף:
 *
 *     flutter build apk --release --target-platform android-arm -Pabis=armeabi-v7a
 *
 * **רשימה אחת מזינה את שני המקומות, וזה העיקר כאן.** ndk.abiFilters חל על
 * קוד שנבנה כאן ולא על .so מוכן שמגיע בתוך ה-AAR של תוסף – ולכן צמצום
 * דרכו לבדו משאיר תיקיית lib/<abi>/ ובה ספריית תוסף בודדת, **בלי
 * libflutter.so**. די בקיום התיקייה כדי שאנדרואיד יצהיר על אותו ABI
 * כנתמך, יבחר בה על מכשיר כזה, ויקרוס בעלייה – כשל גרוע מ"לא תואם", כי
 * הוא מתגלה מאוחר. packaging.jniLibs.excludes הוא מה שמוחק את התיקייה
 * כולה, ולכן שתיהן נגזרות מ-keptAbis.
 *
 * **חייב להישאר מסונכרן עם --target-platform**: הדגל מצמצם את מנוע Flutter
 * בלבד, והתוספים ממשיכים לתרום .so לכל ARM.
 *
 * הכלל אחרי כל בנייה מצומצמת: לוודא ש-`unzip -l` מראה libflutter.so בכל
 * תיקיית lib/ שנשארה. בדיקה ב-ui_test מקבעת שהרשימה אחת.
 */
val keptAbis: List<String> =
    (project.findProperty("abis") as String?)
        ?.split(",")?.map { it.trim() }?.filter { it.isNotEmpty() }
        ?: listOf("armeabi-v7a", "arm64-v8a")

android {
    namespace = "com.example.events_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // נדרש עבור flutter_local_notifications (desugaring של java.time).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.events_app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // רק ARM נארז: x86_64 באנדרואיד הוא אמולטור או Chromebook, ובלי
        // הצמצום נוצרת עבורו תיקייה שלמה בקובץ שאיש לא יתקין ממנה.
        // המחיר הוא לוותר על הרצה באמולטור x86 – בנייה לאמולטור דורשת
        // להסיר את שתי ההגדרות, או `-Pabis=x86_64`.
        ndk {
            abiFilters += keptAbis
        }
    }

    // נגזר מ-keptAbis ולא נכתב ביד: כל ABI שאינו ברשימה נמחק **לגמרי**,
    // ולא רק הקוד שנבנה כאן. ראה את ההסבר ליד keptAbis – זה החצי שמונע
    // תיקייה חצי-ריקה שגורמת לקריסה בעלייה.
    packaging {
        jniLibs {
            excludes += ALL_ABIS.filterNot { keptAbis.contains(it) }
                .map { "lib/$it/**" }.toSet()
        }
    }

    buildTypes {
        release {
            // חתימת debug כדי לאפשר `flutter run --release` ללא הגדרת keystore.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

// ב-Kotlin 2.x זהו ה-DSL הנכון; kotlinOptions בתוך android { } מיושן.
kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // ספריית desugaring הנדרשת ל-flutter_local_notifications.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
