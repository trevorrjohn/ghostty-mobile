import com.android.build.api.dsl.ApplicationExtension

apply(plugin = "com.android.application")

configure<ApplicationExtension> {
    namespace = "dev.ghostty.connect"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.ghostty.connect"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    buildFeatures {
        buildConfig = true
    }
}

dependencies {
    add("implementation", "com.hierynomus:sshj:0.40.0")
    add("implementation", "org.bouncycastle:bcprov-jdk18on:1.80.2")
}
