plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing comes from the environment (GitHub Actions secrets, see
// docs/release_ci_Claude-11-02-2026_18-29-26.md). Without it a release build is signed with the debug key,
// which can run but cannot update an installed release build.
val releaseKeystore: String? = System.getenv("ARCE_KEYSTORE_PATH")
val releasePassword: String? = System.getenv("ARCE_KEYSTORE_PASSWORD")
val releaseKeyAlias: String? = System.getenv("ARCE_KEY_ALIAS")
val hasReleaseSigning = listOf(releaseKeystore, releasePassword, releaseKeyAlias).all { !it.isNullOrEmpty() }

android {
    namespace = "ai.arce.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "29.0.13113456"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Same id and key as the earlier native app, so installed copies update in place.
        applicationId = "ai.arce.app"
        // Android 12 (2021) through the current release: "latest minus five years"
        minSdk = 31
        targetSdk = flutter.targetSdkVersion
        // The build passes --build-name / --build-number (the CI run number); versionCode must only grow.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        externalNativeBuild {
            cmake {
                arguments += "-DCMAKE_BUILD_TYPE=Release"
                arguments += "-DGGML_VULKAN=${if (project.findProperty("arce.ggml.vulkan") == "true") "ON" else "OFF"}"
                arguments += "-DGGML_OPENCL=${if (project.findProperty("arce.ggml.opencl") == "true") "ON" else "OFF"}"
                // Reuse compiled objects between builds (CI sets -Parce.ccache=true; needs ccache on PATH)
                if (project.findProperty("arce.ccache") == "true") {
                    arguments += "-DCMAKE_C_COMPILER_LAUNCHER=ccache"
                    arguments += "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
                }
            }
        }
    }

    externalNativeBuild {
        cmake {
            path("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseKeystore!!)
                // keytool's default PKCS12 keystores use one password for the store and the key
                storePassword = releasePassword
                keyAlias = releaseKeyAlias
                keyPassword = releasePassword
            }
        }
    }

    buildTypes {
        release {
            // JNI classes of llama.cpp and LiteRT-LM must keep their names; nothing here needs shrinking.
            isMinifyEnabled = false
            isShrinkResources = false
            signingConfig = if (hasReleaseSigning) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
        }
    }

    packaging {
        jniLibs {
            // Extract the .so files at install time (and store them compressed in the APK). Android runs a
            // program only from a file on disk, and proot (libproot.so, libproot_loader.so) is one: it is
            // started as a process from nativeLibraryDir. Measured in docs/linux_environment_Claude-11-02-2026_18-29-26.md: the APK gets
            // smaller (131 -> 68 MB), the device needs ~117 MB of disk for the libraries, and a delta
            // update patch is larger (1.1 -> 5.9 MB).
            useLegacyPackaging = true
            // LiteRT-LM and Flutter may both bring the shared C++ runtime.
            pickFirsts += "**/libc++_shared.so"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.17.1")
}

flutter {
    source = "../.."
}
