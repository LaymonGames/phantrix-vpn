// Android library build for the Phantrix platform bridge.
//
// Written against the Android Gradle Plugin 9 Kotlin DSL, which is what the
// host application uses. A Groovy `build.gradle` here is silently ignored
// under AGP 9, which fails in a confusing way, so this file is `.kts` and
// stays that way.
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
	id("com.android.library")
	id("org.jetbrains.kotlin.android")
}

// The WireGuard tunnel library, which is the real protocol implementation.
//
// Coordinates verified against Maven Central's own metadata on 2026-01-02:
//   groupId    com.wireguard.android
//   artifactId tunnel
//   version    1.0.20260102   (latest release listed in maven-metadata.xml)
//   license    Apache-2.0
//   sha256     2b9c16db026496123e4db695d26d03d1958a201096c7c4c89b21077dc70f3119
//
// The checksum is additionally pinned in `gradle/verification-metadata.xml`
// so a clean checkout refuses a substituted artifact. This is the official
// WireGuard userspace engine, compiled to `libwg-go.so` for arm64-v8a,
// armeabi-v7a, x86 and x86_64. Phantrix does not implement, and must never
// implement, any WireGuard cryptography itself.
val wireguardTunnelVersion = "1.0.20260102"

android {
	namespace = "dev.phantrix.phantrix_platform"
	compileSdk = 35
	ndkVersion = flutter.ndkVersion

	compileOptions {
		sourceCompatibility = JavaVersion.VERSION_17
		targetCompatibility = JavaVersion.VERSION_17
	}

	sourceSets {
		getByName("main") {
			java.srcDir("src/main/kotlin")
		}
		// JVM unit tests for the pure-Kotlin parts that need no device.
		getByName("test") {
			java.srcDir("src/test/kotlin")
		}
	}

	defaultConfig {
		// 24, not 21: the WireGuard tunnel library's own manifest declares
		// `minSdkVersion="24"`. Declaring a lower value here would merge to a
		// manifest the library cannot honour, and the failure would only show
		// up on a real device.
		minSdk = 24

		// Keep rules that must travel with the library (the Go WireGuard backend
		// is reached through JNI by name).
		consumerProguardFiles("consumer-rules.pro")

		// Required for the on-device engine tests in `src/androidTest`. Those
		// tests load the real `libwg-go.so` from inside the APK and drive the
		// real `GoBackend`, which is the only way to prove the native engine
		// actually works on a device rather than merely compiling.
		testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
	}

	buildFeatures {
		// The Go backend resolves `System.loadLibrary` for libwg-go.so at
		// runtime; the consumer rules below keep it from being stripped.
		buildConfig = true
	}

	testOptions {
		unitTests.isReturnDefaultValues = true
	}
}

dependencies {
	// The real WireGuard implementation. See the note above.
	api("com.wireguard.android:tunnel:$wireguardTunnelVersion")

	// NotificationCompat, for the mandatory foreground-service notification.
	implementation("androidx.core:core-ktx:1.15.0")
	implementation("androidx.annotation:annotation:1.9.1")

	testImplementation("junit:junit:4.13.2")

	// A real `org.json` implementation for the JVM unit tests.
	//
	// The one on the Android unit-test classpath comes from `android.jar`, whose
	// methods are stubs that return null when `unitTests.returnDefaultValues` is
	// on — so `JSONObject.put` chains to a null and every test that builds a
	// request dies on an NPE that has nothing to do with the parser. This is the
	// upstream JSON reference implementation, which is what `org.json` really is
	// on a device.
	//
	// `testImplementation`, not `implementation`: the library ships the platform's
	// `org.json`, and putting a second copy on the compile classpath would make
	// the app build against a different one than it runs against.
	testImplementation("org.json:json:20240303")

	// On-device engine tests. These run the real native library, so they
	// execute on a device or emulator via `connectedAndroidTest` and are
	// deliberately kept out of `test`, which runs on the JVM where no native
	// library can be loaded and every assertion would be meaningless.
	androidTestImplementation("androidx.test.ext:junit:1.2.1")
	androidTestImplementation("androidx.test:runner:1.6.2")
	androidTestImplementation("androidx.test:core:1.6.1")
}

kotlin {
	compilerOptions {
		jvmTarget.set(JvmTarget.JVM_17)
	}
}
