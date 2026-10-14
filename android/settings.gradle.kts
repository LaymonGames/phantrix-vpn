pluginManagement {
    // `local.properties` is machine-local and intentionally is not committed.
    // A clean checkout may therefore be opened by an IDE before Flutter has
    // generated that file. Prefer its configured path, then fall back to the
    // standard FLUTTER_ROOT / FLUTTER_HOME environment variables.
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        val localProperties = file("local.properties")
        if (localProperties.isFile) {
            localProperties.inputStream().use { properties.load(it) }
        }

        val configuredPath = properties.getProperty("flutter.sdk")
            ?.takeIf { it.isNotBlank() }
            ?: System.getenv("FLUTTER_ROOT")?.takeIf { it.isNotBlank() }
            ?: System.getenv("FLUTTER_HOME")?.takeIf { it.isNotBlank() }

        require(configuredPath != null) {
            "Flutter SDK not configured. Run `flutter pub get` from the project root " +
                "or set FLUTTER_ROOT to the Flutter SDK directory."
        }

        val gradlePlugin = file("$configuredPath/packages/flutter_tools/gradle")
        require(gradlePlugin.isDirectory) {
            "Flutter SDK path does not contain packages/flutter_tools/gradle: $configuredPath"
        }
        configuredPath
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
