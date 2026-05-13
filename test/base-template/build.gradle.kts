plugins {
    kotlin("jvm") version "2.1.20"
    id("io.ktor.plugin") version "3.3.2"
    id("com.google.devtools.ksp") version "2.1.20-2.0.1"
    id("com.airbnb.viaduct.application-gradle-plugin") version "1.0.0"
    id("com.airbnb.viaduct.module-gradle-plugin") version "1.0.0"
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

dependencies {
    // Ktor
    implementation("io.ktor:ktor-server-core:3.3.2")
    implementation("io.ktor:ktor-server-netty:3.3.2")
    implementation("io.ktor:ktor-server-content-negotiation:3.3.2")
    implementation("io.ktor:ktor-serialization-jackson:3.3.2")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-jdk8:1.10.2")
    implementation("org.jetbrains.kotlin:kotlin-reflect:2.1.20")

    // Jackson
    implementation("com.fasterxml.jackson.module:jackson-module-kotlin:2.17.0")

    // Viaduct
    implementation("com.airbnb.viaduct:api:1.0.0")
    implementation("com.airbnb.viaduct:runtime:1.0.0")
    implementation("org.reactivestreams:reactive-streams:1.0.4")

    // Logging
    implementation("ch.qos.logback:logback-classic:1.4.14")

    // Testing
    testImplementation("io.ktor:ktor-server-tests:3.3.2")
    testImplementation("org.jetbrains.kotlin:kotlin-test:2.1.20")
    testImplementation("com.airbnb.viaduct:test-fixtures:1.0.0")
}
