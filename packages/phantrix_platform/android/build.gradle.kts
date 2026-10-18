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

// The plugin has no third-party dependencies. It speaks to the Flutter engine
// on one side and to the Android framework on the other, and both arrive with
// the toolchain: the Flutter Gradle plugin puts the embedding on the compile
// classpath, and the framework classes come from `compileSdk`.

android {
	namespace = "dev.phantrix.phantrix_platform"
	compileSdk = 35

	compileOptions {
		sourceCompatibility = JavaVersion.VERSION_17
		targetCompatibility = JavaVersion.VERSION_17
	}

	sourceSets {
		getByName("main") {
			java.srcDir("src/main/kotlin")
		}
	}

	defaultConfig {
		// 24: the API floor the app supports. Nothing here needs a newer one,
		// and declaring a lower one would let the app install where the
		// plugin's behaviour was never exercised.
		minSdk = 24

		// Keep rules that travel with the library: the plugin class is reached
		// by name from the engine's plugin registrar, which R8 cannot trace.
		consumerProguardFiles("consumer-rules.pro")
	}
}

kotlin {
	compilerOptions {
		jvmTarget.set(JvmTarget.JVM_17)
	}
}
