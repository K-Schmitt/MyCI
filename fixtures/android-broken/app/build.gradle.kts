plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "fixture.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "fixture.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }
}

dependencies {
    testImplementation(libs.junit)
}
