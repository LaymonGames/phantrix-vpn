import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// Release signing
// ---------------------------------------------------------------------------
//
// The release key is the project's identity, so it belongs to whoever ships
// the app and cannot be generated here or committed to the repository. What
// this build needs from them is a `key.properties` file next to this one:
//
//     storeFile=/absolute/or/relative/path/to/phantrix-upload.jks
//     storePassword=...
//     keyAlias=upload
//     keyPassword=...
//
// `key.properties` is listed in `.gitignore`. When it is absent the build
// still succeeds — signing a release with the debug key keeps `flutter run
// --release` usable during development — but it says so loudly, because the
// difference between a debug-signed and a release-signed APK is invisible in
// the file list and catastrophic on upload: the Play Store rejects it, and a
// key swapped after first upload cannot be replaced at all.

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}
val hasReleaseKey = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "dev.phantrix.phantrix"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.phantrix.phantrix"
        // Explicit rather than `flutter.minSdkVersion`: API 24 is the floor
        // this app is tested against, and inheriting a lower default would
        // produce an APK whose manifest lies about what it supports.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                // Play App Signing expects the v1 and v2 schemes; v3 is added for
                // key rotation support on newer devices. Leaving v4 off keeps
                // the build reproducible, since v4 adds an extra `.idsig`
                // sidecar that is not part of the APK.
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "Phantrix: android/key.properties is missing, so the release " +
                        "build is signed with the DEBUG key. The APK will install and " +
                        "run, but it cannot be published: the Play Store rejects " +
                        "debug-signed artifacts, and once an upload has used a key " +
                        "that key can never be replaced. See docs/BUILDING.md."
                )
                signingConfigs.getByName("debug")
            }

            // Shrink and obfuscate. The app ships a Dart AOT snapshot rather
            // than Java or Kotlin bytecode, so this mainly reduces the size of
            // the Android support library and the WireGuard bridge; the Dart
            // code is already stripped by the AOT compiler.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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
