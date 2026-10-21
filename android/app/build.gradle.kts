import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties
import java.security.MessageDigest
import groovy.json.JsonSlurper

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

val localPropertiesFile = rootProject.file("local.properties")
val localProperties = Properties().apply {
    if (localPropertiesFile.exists()) {
        localPropertiesFile.inputStream().use { load(it) }
    }
}

val mStoreFile: File = file("keystore.jks")
val mStorePassword: String? = localProperties.getProperty("storePassword")
val mKeyAlias: String? = localProperties.getProperty("keyAlias")
val mKeyPassword: String? = localProperties.getProperty("keyPassword")
val isRelease =
    mStoreFile.exists() && mStorePassword != null && mKeyAlias != null && mKeyPassword != null

// ── Xboard 多品牌（既有接缝 #4）：prepare_flavor 解码 YAML，Gradle 消费公开 JSON。──
// XBOARD_ANDROID_IDENTITY_BEGIN
fun androidBrandIdentity(flavor: String): Map<String, String>? {
    val root = rootProject.projectDir.parentFile
    val source = File(root, "flavors/$flavor/flavor.yaml")
    if (!source.exists()) return null // Unconfigured upstream/other-brand variant.
    val generated = File(root, ".dart_tool/xboard/android_brand_identity.json")
    fun invalid(): Nothing = throw GradleException(
        "Android brand identity missing, invalid or stale for $flavor; run dart run tool/prepare_flavor.dart --flavor $flavor --android-identity"
    )
    val document = try {
        JsonSlurper().parseText(generated.readText(Charsets.UTF_8)) as? Map<*, *>
    } catch (_: Exception) { invalid() }
    if (document == null || document["schemaVersion"] != 1) invalid()
    val identities = document["brands"] as? Map<*, *> ?: invalid()
    val identity = identities[flavor] as? Map<*, *> ?: invalid()
    val name = identity["appName"] as? String ?: invalid()
    val id = identity["appId"] as? String ?: invalid()
    val digest = MessageDigest.getInstance("SHA-256").digest(source.readBytes())
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }
    if (identity["sourceSha256"] != digest || name.isBlank() ||
        name.any { it.code < 0x20 || it.code in 0x7f..0x9f } ||
        !Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+").matches(id)) invalid()
    return mapOf("appName" to name, "appId" to id)
}
// XBOARD_ANDROID_IDENTITY_END


android {
    namespace = "com.follow.clash"
    compileSdk = libs.versions.compileSdk.get().toInt()
    ndkVersion = libs.versions.ndkVersion.get()



    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.follow.clash"
        minSdk = flutter.minSdkVersion
        targetSdk = libs.versions.targetSdk.get().toInt()
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // ── 单 ABI 过滤（自分发用）──
        // 自分发只发单一 arm64 包：用 abiFilters 限定 ABI，避免 --split-per-abi 给 versionCode
        // 加 abi 偏移（如 arm64 的 2000+），让 versionCode == build-number（后台配版本号才对得上）。
        // 经 local.properties 传值（不用 env：gradle 守护进程的 env 会陈旧，export 后读不到；
        // local.properties 每次配置都重读，无配置缓存）。scripts/build_local.sh 构建时临时写入、构建后移除。
        // 为空（IDE / flutter run）则不过滤，保留多 ABI 正常调试。
        localProperties.getProperty("XB_TARGET_ABI")?.takeIf { it.isNotBlank() }?.let { abi ->
            ndk {
                abiFilters.clear()   // flutter 插件会预填全部 ABI；先清空再设单一目标
                abiFilters.add(abi)
            }
        }
    }

    signingConfigs {
        if (isRelease) {
            create("release") {
                storeFile = mStoreFile
                storePassword = mStorePassword
                keyAlias = mKeyAlias
                keyPassword = mKeyPassword
            }
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
            applicationIdSuffix = ".dev"
        }

        release {
            isMinifyEnabled = true
            isShrinkResources = true
            if (isRelease) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                signingConfig = signingConfigs.getByName("debug")
                applicationIdSuffix = ".dev"
            }

            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro"
            )
        }
    }

    // Both identities are decoded by prepare_flavor's full YAML parser.
    // Missing YAML retains the unconfigured upstream variant; existing YAML with
    // missing/stale generated identity fails before Android compilation.
    flavorDimensions += "brand"
    productFlavors {
        create("brand_a") {
            dimension = "brand"
            val identity = androidBrandIdentity("brand_a")
            applicationId = identity?.get("appId") ?: "com.follow.clash"
            manifestPlaceholders["appName"] = identity?.get("appName") ?: "FlClash"
        }
        create("brand_b") {
            dimension = "brand"
            val identity = androidBrandIdentity("brand_b")
            applicationId = identity?.get("appId") ?: "com.follow.clash"
            manifestPlaceholders["appName"] = identity?.get("appName") ?: "FlClash"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}


dependencies {
    implementation(project(":service"))
    implementation(project(":common"))
    implementation(libs.core.splashscreen)
    implementation(libs.gson)
    implementation(libs.smali.dexlib2) {
        exclude(group = "com.google.guava", module = "guava")
    }
    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.crashlytics.ndk)
    implementation(libs.firebase.analytics)
}