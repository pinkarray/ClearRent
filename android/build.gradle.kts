allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// agora_rtc_engine 6.6.4 and its iris_method_channel compile against API 31,
// but their androidx dependencies need 34+, which fails checkAarMetadata.
// Raise only those two.
// Must be registered before evaluationDependsOn below evaluates it.
subprojects {
    if (name == "agora_rtc_engine" || name == "iris_method_channel") {
        afterEvaluate {
            extensions.configure<com.android.build.gradle.LibraryExtension>("android") {
                compileSdk = 36
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
