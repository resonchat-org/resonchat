plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Dev builds (`RESONCHAT_DEV_BUILD=1`, set by scripts/dev_android.sh) are for
// the real-device test loop: the version *name* stays put so it is obvious
// which line a build came from, while the version *code* only ever goes up, so
// the installer accepts the new APK over the installed one without an
// uninstall. Android refuses a lower code outright
// (INSTALL_FAILED_VERSION_DOWNGRADE), which is why "same version every time"
// cannot mean a frozen code too. Minutes since the epoch outrank 0.0.4's code
// and stay inside an Int for another few thousand years.
val devBuild = System.getenv("RESONCHAT_DEV_BUILD") == "1"
val devVersionCode: Int =
    System.getenv("RESONCHAT_DEV_VERSION_CODE")?.toIntOrNull()
        ?: (System.currentTimeMillis() / 60_000L).toInt()

android {
    namespace = "org.resonchat.resonchat"
    // file_picker → flutter_plugin_android_lifecycle requires compileSdk ≥ 36.
    compileSdk = maxOf(flutter.compileSdkVersion, 36)
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        aidl = true
    }

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
        versionCode = if (devBuild) devVersionCode else flutter.versionCode
        versionName = if (devBuild) "${flutter.versionName}-dev" else flutter.versionName
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
    implementation("androidx.core:core-ktx:1.15.0")
}
