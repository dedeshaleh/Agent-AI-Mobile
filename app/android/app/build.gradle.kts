plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// unityLibrary is produced by `scripts/Export-Unity.ps1` (Unity → Flutter export) and is
// not committed. The app must still build without it so the Flutter side can be tested
// before the Unity license/export is available; `EmbedUnity` is then compiled out via
// `--dart-define=UNITY_EMBED=false` (the default).
val hasUnityLibrary = rootProject.file("unityLibrary/build.gradle").exists()

android {
    namespace = "id.agenthq.agent_hq"
    compileSdk = flutter.compileSdkVersion
    // Unity 6000.3 ships NDK r27c; the llama.cpp shim is built with the same version.
    ndkVersion = "27.2.12479018"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "id.agenthq.agent_hq"
        // The Unity 6000.3 export declares minSdk 25 (unity.minSdkVersion); the app must not go lower.
        minSdk = maxOf(flutter.minSdkVersion, 25)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // PRD: arm64-v8a only (Infinix X6871).
        ndk {
            abiFilters += listOf("arm64-v8a")
        }

        externalNativeBuild {
            cmake {
                arguments += listOf("-DANDROID_STL=c++_shared", "-DANDROID_PLATFORM=android-26")
            }
        }
    }

    // llama.cpp shim: src/main/cpp/CMakeLists.txt fetches the pinned llama.cpp tag.
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    androidResources {
        // Unity assets are already compressed by the export; recompressing slows startup.
        noCompress += listOf(".unity3d", ".ress", ".resource", ".obb", ".bundle", ".unityexp")
        ignoreAssetsPattern = "!.svn:!.git:!.ds_store:!*.scc:!CVS:!thumbs.db:!picasa.ini:!*~"
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

dependencies {
    if (hasUnityLibrary) {
        implementation(project(":unityLibrary"))
    }
}

flutter {
    source = "../.."
}
