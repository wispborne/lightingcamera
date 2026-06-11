plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.wisp.lightingcamera"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.wisp.lightingcamera"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Wisp: For the native code
        externalNativeBuild {
            cmake {
                cppFlags.add("-std=c++17")
                arguments.add("-DANDROID_STL=c++_shared")
            }
        }

    }

    // Wisp: For the native code
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.29.0-rc1"
        }
    }


    buildTypes {
        debug {
            applicationIdSuffix = ".dev"
            resValue("string", "app_name", "LC Dev")
        }
        release {
            signingConfig = signingConfigs.getByName("debug")
            resValue("string", "app_name", "lightingcamera")
        }
    }
}

flutter {
    source = "../.."
}
