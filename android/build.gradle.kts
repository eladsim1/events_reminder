allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// מעביר את תיקיית ה-build אל שורש הפרויקט (מחוץ ל-android/).
// חשוב: set() ולא value() – value() מקבל Directory או Provider<Directory>
// בלבד, ולכן העברת java.io.File נכשלת בקומפילציה של סקריפט ה-Gradle.
val newBuildDir: java.io.File = rootProject.layout.buildDirectory.dir("../../build").get().asFile
rootProject.layout.buildDirectory.set(newBuildDir)

subprojects {
    val newSubprojectBuildDir: java.io.File = newBuildDir.resolve(project.name)
    project.layout.buildDirectory.set(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
