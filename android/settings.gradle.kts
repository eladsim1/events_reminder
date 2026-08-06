pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // AGP 8.x במכוון ולא 9.x: ב-AGP 9 שני הפלאגינים סותרים זה את זה —
    // file_picker 11 מדלג על KGP ומצפה ל-Kotlin מובנה, בעוד ש-Flutter
    // מחיל kotlin-android על flutter_local_notifications ונכשל ב-NPE.
    // 8.13.2 תומך ב-compileSdk 36 (flutter_local_notifications עצמו בונה
    // עם AGP 8.11.1 מול compileSdk 36).
    id("com.android.application") version "8.13.2" apply false
    id("org.jetbrains.kotlin.android") version "2.1.20" apply false
}

include(":app")
