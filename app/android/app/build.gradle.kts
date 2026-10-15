plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "org.resonchat.resonchat"
    // file_picker → flutter_plugin_android_lifecycle requires compileSdk ≥ 36.
    compileSdk = maxOf(flutter.compileSdkVersion, 36)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications needs desugaring for java.time APIs
        // on older Android (even without scheduled notifications).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "org.resonchat.resonchat"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true

        // Default: arm64-v8a (devices) + x86_64 (emulator). CD sets
        // RESONCHAT_ANDROID_ABIS=arm64-v8a|x86_64 for split APKs.
        // 32-bit ABIs are dropped (docs/04 §2.3).
        ndk {
            abiFilters.clear()
            val fromEnv = System.getenv("RESONCHAT_ANDROID_ABIS")
            val fromProp = project.findProperty("androidAbis") as String?
            val abis = (fromEnv ?: fromProp)
                ?.split(',')
                ?.map { it.trim() }
                ?.filter { it.isNotEmpty() }
                ?: listOf("arm64-v8a", "x86_64")
            abiFilters += abis
        }
        // OMEMO2 uses pure-Dart pqcrypto ML-KEM-1024 (+ libsignal native
        // Kyber for PQXDH/SPQR).
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
