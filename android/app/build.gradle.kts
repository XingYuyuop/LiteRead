import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 签名配置优先级：
// 1. android/key.properties（本地/CI 注入，不入库）
// 2. 仓库内置 android/app/literead-release.jks（固定发布密钥，保证历次 CI
//    构建签名一致，旧版本可直接覆盖安装更新）
// 3. debug 签名（仅本地无密钥时兜底）
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

val bundledKeystore = file("literead-release.jks")

android {
    namespace = "dev.literead.literead"
    // file_picker → flutter_plugin_android_lifecycle 要求 compileSdk >= 36
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.literead.literead"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        } else if (bundledKeystore.exists()) {
            create("release") {
                keyAlias = "literead"
                keyPassword = "LiteRead2026!"
                storeFile = bundledKeystore
                storePassword = "LiteRead2026!"
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists() || bundledKeystore.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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
