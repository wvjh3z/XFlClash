import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

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

// ── Xboard 多品牌（接缝点 #4）：从 flavors/<name>/flavor.yaml 读品牌身份（appId/appName）──
// flavor.yaml 是品牌配置 SSoT（gitignored；本地存值 / CI 还原）。gradle 配置期直读，避免把品牌
// 值硬编码进 build.gradle 或塞进 dart-define（NFR-2）。appId/appName 是单行字符串，逐行正则即可。
// rootProject.projectDir = android/；其 parentFile = 仓库根（XFlClash/），flavors 在仓库根下。
fun flavorYamlValue(flavor: String, key: String): String? {
    val f = File(rootProject.projectDir.parentFile, "flavors/$flavor/flavor.yaml")
    if (!f.exists()) return null
    val re = Regex("^\\s*$key\\s*:\\s*\"?([^\"#]+?)\"?\\s*(?:#.*)?$")
    return f.readLines().firstNotNullOfOrNull { re.find(it)?.groupValues?.get(1)?.trim() }
}


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

    // ── 接缝点 #4（W8.4 / D36 / θ-10）：Xboard 多租户 flavor ──
    // applicationId + appName 由各 flavor 从 flavors/<name>/flavor.yaml 读入注入（flavorYamlValue）：
    //   - applicationId：品牌包名（debug / unsigned-release 再叠加 buildType 的 .dev 后缀）。
    //   - manifestPlaceholders["appName"]：品牌显示名，main manifest 的 android:label="${appName}" 消费。
    // 缺字段/缺 flavor.yaml 时回退 upstream com.follow.clash / FlClash（不崩，但应保证 yaml 齐全）。
    flavorDimensions += "brand"
    productFlavors {
        create("brand_a") {
            dimension = "brand"
            applicationId = flavorYamlValue("brand_a", "appId") ?: "com.follow.clash"
            manifestPlaceholders["appName"] = flavorYamlValue("brand_a", "appName") ?: "FlClash"
        }
        create("brand_b") {
            dimension = "brand"
            applicationId = flavorYamlValue("brand_b", "appId") ?: "com.follow.clash"
            manifestPlaceholders["appName"] = flavorYamlValue("brand_b", "appName") ?: "FlClash"
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