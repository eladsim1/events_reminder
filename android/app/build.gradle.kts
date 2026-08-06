plugins {
    id("com.android.application")
    id("kotlin-android")
    // Flutter Gradle Plugin חייב לבוא אחרי פלאגיני Android ו-Kotlin.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.azkarot_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // נדרש עבור flutter_local_notifications (desugaring של java.time).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.azkarot_app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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
