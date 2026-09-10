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
        create("release") {
            storeFile = file(providers.environmentVariable("SEANCE_UPLOAD_STORE_FILE").getOrElse("missing-seance-shell-upload.jks"))
            storePassword = providers.environmentVariable("SEANCE_UPLOAD_STORE_PASSWORD").getOrElse("")
            keyAlias = providers.environmentVariable("SEANCE_UPLOAD_KEY_ALIAS").getOrElse("")
            keyPassword = providers.environmentVariable("SEANCE_UPLOAD_KEY_PASSWORD").getOrElse("")
        }
    }

    buildTypes {
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
