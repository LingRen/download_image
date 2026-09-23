pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
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
    // 不用 Flutter 3.47.4 模板默认的 AGP 9.1.0：flutter_inappwebview_android 1.1.3
    // 的 build.gradle 仍在用 AGP 9 已移除的 getDefaultProguardFile('proguard-android.txt')，
    // 会在配置阶段抛 EvalIssueException 导致 Android 无法构建。8.13.0 是 Flutter 3.47.4
    // 兼容表里最高的 8.x（要求 Gradle ≥8.13，上限 9.3.1，与当前 wrapper 一致）。
    id("com.android.application") version "8.13.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
