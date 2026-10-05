plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val telegramBotToken = providers.gradleProperty("telegramBotToken")
    .orElse(providers.environmentVariable("TELEGRAM_BOT_TOKEN"))
    .orElse("")

val telegramChatId = providers.gradleProperty("telegramChatId")
    .orElse(providers.environmentVariable("TELEGRAM_CHAT_ID"))
    .orElse("")

val telegramThreadId = providers.gradleProperty("telegramThreadId")
    .orElse(providers.environmentVariable("TELEGRAM_THREAD_ID"))
    .orElse("")

android {
    namespace = "com.homefelipev.healthcoach"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.homefelipev.healthcoach"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        buildConfigField("String", "TELEGRAM_BOT_TOKEN", "\"${telegramBotToken.get()}\"")
        buildConfigField("String", "TELEGRAM_CHAT_ID", "\"${telegramChatId.get()}\"")
        buildConfigField("String", "TELEGRAM_THREAD_ID", "\"${telegramThreadId.get()}\"")
    }

    buildFeatures { compose = true; buildConfig = true }
    testOptions { unitTests.isIncludeAndroidResources = true }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation(platform("androidx.compose:compose-bom:2025.10.00"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.health.connect:connect-client:1.1.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.9.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.4")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.mockito:mockito-core:5.20.0")
    testImplementation("org.robolectric:robolectric:4.16.1")
}
