import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties
import java.security.MessageDigest
import groovy.json.JsonSlurper

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val localProperties = Properties().apply {
    val localPropertiesFile = rootProject.file("local.properties")
    if (localPropertiesFile.exists()) {
        localPropertiesFile.inputStream().use { load(it) }
    }
}

val releaseStoreFile = file("keystore.jks")
val releaseStorePassword = localProperties.getProperty("storePassword")
val releaseKeyAlias = localProperties.getProperty("keyAlias")
val releaseKeyPassword = localProperties.getProperty("keyPassword")
val hasReleaseSigning = releaseStoreFile.exists() &&
    releaseStorePassword != null &&
    releaseKeyAlias != null &&
    releaseKeyPassword != null

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

    // AGP 9 disables generated resource values by default. Both brands use
    // app_name for the launcher and recent-task label.
    buildFeatures {
        resValues = true
    }

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

        // Local ARM64 and CI split APKs share the final versionCode policy below.
        // ABI filtering selects libraries only; product build numbers remain unchanged.
        localProperties.getProperty("XB_TARGET_ABI")?.takeIf { it.isNotBlank() }?.let { abi ->
            ndk {
                abiFilters.clear()   // flutter 插件会预填全部 ABI；先清空再设单一目标
                abiFilters.add(abi)
            }
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = releaseStoreFile
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
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
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                signingConfig = signingConfigs.getByName("debug")
                applicationIdSuffix = ".dev"
            }

            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
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
            resValue("string", "app_name", identity?.get("appName") ?: "FlClash")
        }
        create("brand_b") {
            dimension = "brand"
            val identity = androidBrandIdentity("brand_b")
            applicationId = identity?.get("appId") ?: "com.follow.clash"
            manifestPlaceholders["appName"] = identity?.get("appName") ?: "FlClash"
            resValue("string", "app_name", identity?.get("appName") ?: "FlClash")
        }
    }

    sourceSets {
        // Unit tests live under android/tests/ instead of each module's src/test.
        getByName("test").java.setSrcDirs(listOf("../tests/app"))
    }
}

// App callbacks run after Flutter's ABI version offsets. Never allow local and
// split APKs of the same product build to use different installer versions.
val androidVersionPolicy = JsonSlurper().parse(rootProject.file("../tool/android_version_policy.json")) as Map<*, *>
val androidVersionOffset = (androidVersionPolicy["offset"] as Number).toLong()
val androidVersionMaximum = (androidVersionPolicy["maximum"] as Number).toLong()
androidComponents {
    onVariants(selector().all()) { variant ->
        val brand = variant.productFlavors.firstOrNull { it.first == "brand" }?.second
        if (brand != null && androidBrandIdentity(brand) != null) {
            val build = flutter.versionCode.toLong()
            require(build > 0 && build <= androidVersionMaximum - androidVersionOffset) {
                "Product build number exceeds the Android installer version range"
            }
            variant.outputs.forEach { output ->
                output.versionCode.set((androidVersionOffset + build).toInt())
            }
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
    implementation(project(":core"))
    implementation(libs.core.splashscreen)
    implementation(libs.gson)
    implementation(libs.smali.dexlib2) {
        exclude(group = "com.google.guava", module = "guava")
    }
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
