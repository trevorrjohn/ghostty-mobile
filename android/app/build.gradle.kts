import com.android.build.api.dsl.ApplicationExtension

apply(plugin = "com.android.application")

configure<ApplicationExtension> {
    namespace = "dev.ghostty.connect"
    compileSdk = 36
    ndkVersion = "27.1.12297006"

    defaultConfig {
        applicationId = "fail.founder.terminal"
        minSdk = 29
        targetSdk = 36
        versionCode = 2
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        ndk {
            abiFilters += setOf("arm64-v8a", "x86_64")
        }

        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++20"
            }
        }
    }

    buildFeatures {
        buildConfig = true
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    signingConfigs {
        create("debugRepo") {
            storeFile = rootProject.file("debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
        create("release") {
            storeFile = file(providers.environmentVariable("SEANCE_UPLOAD_STORE_FILE").getOrElse("missing-seance-shell-upload.jks"))
            storePassword = providers.environmentVariable("SEANCE_UPLOAD_STORE_PASSWORD").getOrElse("")
            keyAlias = providers.environmentVariable("SEANCE_UPLOAD_KEY_ALIAS").getOrElse("")
            keyPassword = providers.environmentVariable("SEANCE_UPLOAD_KEY_PASSWORD").getOrElse("")
        }
    }

    buildTypes {
        getByName("debug") {
            signingConfig = signingConfigs.getByName("debugRepo")
        }
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

dependencies {
    add("implementation", "com.hierynomus:sshj:0.40.0")
    add("implementation", "org.bouncycastle:bcprov-jdk18on:1.80.2")
    add("testImplementation", "junit:junit:4.13.2")
    add("androidTestImplementation", "androidx.test:runner:1.6.2")
    add("androidTestImplementation", "androidx.test.ext:junit:1.2.1")
}

// Shared Zig core (see ADR 0012). Built locally with the mise-pinned Zig.
val repoRoot = rootProject.projectDir.parentFile

val buildSeanceCoreAndroid by tasks.registering(Exec::class) {
    description = "Builds libseance_core.a for the Android ABIs"
    workingDir = repoRoot
    commandLine("mise", "x", "--", "core/scripts/build-android")
    inputs.dir(File(repoRoot, "core/src"))
    inputs.file(File(repoRoot, "core/build.zig"))
    outputs.files(
        File(repoRoot, "android/app/src/main/cpp/lib/arm64-v8a/libseance_core.a"),
        File(repoRoot, "android/app/src/main/cpp/lib/x86_64/libseance_core.a"),
    )
}

val buildSeanceCoreHost by tasks.registering(Exec::class) {
    description = "Builds the host libseance_core for JVM unit tests"
    workingDir = repoRoot
    commandLine("mise", "x", "--", "zig", "build", "--build-file", "core/build.zig", "--prefix", "core/zig-out/host", "host-jni")
    inputs.dir(File(repoRoot, "core/src"))
    inputs.file(File(repoRoot, "core/build.zig"))
    outputs.dir(File(repoRoot, "core/zig-out/host"))
}

val checkGhosttyPin by tasks.registering(Exec::class) {
    description = "Fails if iOS and Android pin different libghostty-vt revisions"
    workingDir = repoRoot
    commandLine("scripts/check-ghostty-pin")
}

tasks.named("preBuild") { dependsOn(checkGhosttyPin, buildSeanceCoreAndroid) }

tasks.withType<Test>().configureEach {
    dependsOn(buildSeanceCoreHost)
    systemProperty("java.library.path", File(repoRoot, "core/zig-out/host/lib").absolutePath)
}
