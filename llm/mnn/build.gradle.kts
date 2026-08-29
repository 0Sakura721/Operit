import java.net.URL
import java.io.FileOutputStream
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

// Android ABIs this module builds. Driven by the root `operit.abis` property so
// the default arm64-only build stays unchanged; the armv7 workflow passes
// `-Poperit.abis=armeabi-v7a,arm64-v8a`.
val operitAbis: List<String> =
    ((rootProject.findProperty("operit.abis") as String? ?: "arm64-v8a"))
        .split(",")
        .map { it.trim() }
        .filter { it.isNotEmpty() }

android {
    namespace = "com.ai.assistance.mnn"
    compileSdk = 36

    defaultConfig {
        minSdk = 26
        targetSdk = 34

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        consumerProguardFiles("consumer-rules.pro")

        ndk {
            // 支持的 ABI（由根项目 operit.abis 属性决定，与主 app 保持一致）
            abiFilters.addAll(operitAbis)
        }

        externalNativeBuild {
            cmake {
                cppFlags += listOf("-std=c++17")
                arguments += listOf(
                    "-DANDROID_STL=c++_static",
                    "-DANDROID_PLATFORM=android-26",
                    "-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON",
                    "-DANDROID_ARM_NEON=TRUE",
                    "-DMNN_BUILD_SHARED_LIBS=ON",
                    "-DMNN_SEP_BUILD=OFF",
                    "-DMNN_BUILD_TOOLS=OFF",
                    "-DMNN_BUILD_DEMO=OFF",
                    "-DMNN_BUILD_CONVERTER=OFF",
                    "-DMNN_USE_LOGCAT=ON",
                    "-DMNN_BUILD_TEST=OFF",
                    "-DMNN_BUILD_BENCHMARK=OFF",
                    "-DMNN_BUILD_QUANTOOLS=OFF",
                    "-DMNN_OPENCL=OFF",
                    "-DMNN_OPENGL=OFF",
                    "-DMNN_VULKAN=OFF",
                    "-DMNN_ARM82=ON",
                    // 启用 LLM 支持
                    "-DMNN_BUILD_LLM=ON",
                    "-DMNN_SUPPORT_TRANSFORMER_FUSE=ON",
                    "-DMNN_LOW_MEMORY=ON",
                    "-DMNN_CPU_WEIGHT_DEQUANT_GEMM=ON"
                )
            }
        }
    }


    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    externalNativeBuild {
        cmake {
            path = file("CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_17
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.appcompat)
    
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
}

