import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

// Load keystore properties for release signing
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("app/key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.verealtytech.clearrent"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Update to "com.verealtytech.clearrent" when ready for production.
        // If you change this, you MUST also:
        //   1. Add the new package name in Firebase Console → Project Settings → Add Android App
        //   2. Download the updated google-services.json
        //   3. Rename the folder at android/app/src/main/kotlin/com/example/clearrent
        //      to android/app/src/main/kotlin/com/verealtytech/clearrent
        //   4. Update the package declaration in MainActivity.kt
        applicationId = "com.verealtytech.clearrent"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String? ?: ""
            keyPassword = keystoreProperties["keyPassword"] as String? ?: ""
            storeFile = if ((keystoreProperties["storeFile"] as String?)?.isNotEmpty() == true) {
                file(keystoreProperties["storeFile"] as String)
            } else {
                null
            }
            storePassword = keystoreProperties["storePassword"] as String? ?: ""
        }
    }

    // Agora ships optional extensions we never enable (lip sync, beauty,
    // face tracking, spatial audio, screen share, ...). They only load when
    // switched on in code, and dropping them saves ~18MB per phone. Kept: AI
    // noise suppression, echo cancellation and the standard video codec,
    // which help calls on weak Nigerian networks.
    packaging {
        jniLibs {
            excludes += "**/libagora_lip_sync_extension.so"
            excludes += "**/libagora_clear_vision_extension.so"
            excludes += "**/libagora_spatial_audio_extension.so"
            excludes += "**/libagora_segmentation_extension.so"
            excludes += "**/libagora_face_capture_extension.so"
            excludes += "**/libagora_audio_beauty_extension.so"
            excludes += "**/libagora_content_inspect_extension.so"
            excludes += "**/libagora_video_quality_analyzer_extension.so"
            excludes += "**/libagora_face_detection_extension.so"
            excludes += "**/libagora_video_av1_encoder_extension.so"
            excludes += "**/libagora_screen_capture_extension.so"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")

            // Enable code shrinking and resource shrinking for smaller APK
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
