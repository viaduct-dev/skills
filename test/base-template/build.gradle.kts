plugins {
    kotlin("jvm") version "1.9.25"
    id("io.ktor.plugin") version "3.0.3"
    id("com.google.devtools.ksp") version "1.9.25-1.0.20"
    id("com.airbnb.viaduct.application-gradle-plugin") version "1.1.0-SNAPSHOT"
    id("com.airbnb.viaduct.module-gradle-plugin") version "1.1.0-SNAPSHOT"
}

group = "com.example"
version = "0.0.1"

application {
    mainClass.set("com.example.MainKt")
}

viaductApplication {
    modulePackagePrefix.set("com.example")
}

viaductModule {
    modulePackageSuffix.set("resolvers")
}

repositories {
    mavenLocal()
    mavenCentral()
}

dependencies {
    // Ktor
    implementation("io.ktor:ktor-server-core:3.0.3")
    implementation("io.ktor:ktor-server-netty:3.0.3")
    implementation("io.ktor:ktor-server-content-negotiation:3.0.3")
    implementation("io.ktor:ktor-serialization-jackson:3.0.3")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-jdk8:1.8.1")
    implementation("org.jetbrains.kotlin:kotlin-reflect:1.9.25")

    // Jackson
    implementation("com.fasterxml.jackson.module:jackson-module-kotlin:2.17.0")

    // Viaduct
    implementation("com.airbnb.viaduct:api:1.1.0-SNAPSHOT")
    implementation("com.airbnb.viaduct:runtime:1.1.0-SNAPSHOT")
    implementation("org.reactivestreams:reactive-streams:1.0.4")

    // Logging
    implementation("ch.qos.logback:logback-classic:1.4.14")

    // Testing
    testImplementation("io.ktor:ktor-server-tests:3.0.3")
    testImplementation("org.jetbrains.kotlin:kotlin-test")
}
