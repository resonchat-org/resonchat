pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            // `Properties.load(InputStream)` decodes as ISO-8859-1 by design, so
            // a project under a path with non-ASCII characters (e.g. `项目`)
            // came out as mojibake and the included build below was reported as
            // missing. Flutter writes this file in UTF-8; read it that way.
            file("local.properties").reader(Charsets.UTF_8).use { properties.load(it) }
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
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
