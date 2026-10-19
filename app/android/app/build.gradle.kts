plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.ukpratik.kickfile"
    compileSdk = 37 // permission_handler needs 37+
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true // flutter_local_notifications
    }

    defaultConfig {
        applicationId = "io.github.ukpratik.kickfile"
        minSdk = 26 // A-03: Android 8.0
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release signing comes from ~/.gradle/gradle.properties (kickfile.release.*), never from git.
    // Without those properties the release build is unsigned, which is what F-Droid expects.
    signingConfigs {
        val storeFilePath = providers.gradleProperty("kickfile.release.storeFile").orNull
        if (storeFilePath != null) {
            create("release") {
                storeFile = file(storeFilePath)
                storePassword = providers.gradleProperty("kickfile.release.storePassword").get()
                keyAlias = providers.gradleProperty("kickfile.release.keyAlias").get()
                keyPassword = providers.gradleProperty("kickfile.release.keyPassword").get()
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
        }
    }

    // No Google-signed dependency metadata blob in the APK (F-Droid rejects it).
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
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
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("androidx.core:core-ktx:1.13.1")
}
