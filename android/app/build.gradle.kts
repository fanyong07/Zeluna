import java.io.File
import java.io.FileInputStream
import java.security.KeyStore
import java.security.cert.X509Certificate
import java.util.Properties
import org.gradle.api.Action
import org.gradle.api.GradleException
import org.gradle.api.execution.TaskExecutionGraph

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")

fun producesReleaseArtifact(taskName: String): Boolean {
    val normalizedName = taskName.substringAfterLast(':').lowercase()
    if (!normalizedName.contains("release")) return false
    return listOf("assemble", "bundle", "package", "sign", "install", "publish")
        .any(normalizedName::startsWith)
}

val releaseTaskRequested = gradle.startParameter.taskNames.any {
    producesReleaseArtifact(it)
}
val allowLegacyDebugReleaseSigning =
    providers.gradleProperty("allowLegacyDebugReleaseSigning")
        .orNull
        ?.equals("true", ignoreCase = true) == true
val requiredSigningKeys = listOf(
    "storeFile",
    "storePassword",
    "keyAlias",
    "keyPassword",
)

if (keystorePropertiesFile.isFile) {
    FileInputStream(keystorePropertiesFile).use(keystoreProperties::load)
}

fun signingProperty(name: String): String? =
    keystoreProperties.getProperty(name)?.trim()?.takeIf(String::isNotEmpty)

fun isPlaceholderSigningValue(value: String): Boolean =
    value.matches(Regex("(?i)^(?:replace|change|your|todo|example|placeholder)(?:[-_ ].*)?$")) ||
        value.matches(Regex("^<[^>]+>$"))

val releaseSigningValues = requiredSigningKeys.associateWith(::signingProperty)
val missingSigningKeys = releaseSigningValues
    .filterValues { it == null }
    .keys
    .sorted()
val placeholderSigningKeys = releaseSigningValues
    .filterValues { it != null && isPlaceholderSigningValue(it) }
    .keys
    .sorted()
val releaseStoreFile = releaseSigningValues["storeFile"]?.let { configuredPath ->
    File(configuredPath).let { path ->
        if (path.isAbsolute) path else project.file(configuredPath)
    }.canonicalFile
}
val hasUsableReleaseSigning =
    keystorePropertiesFile.isFile &&
        missingSigningKeys.isEmpty() &&
        placeholderSigningKeys.isEmpty() &&
        releaseStoreFile?.isFile == true

fun validateReleaseKeyStore(
    storeFile: File,
    storePassword: String,
    keyAlias: String,
    keyPassword: String,
) {
    var loadFailure: Exception? = null
    for (keyStoreType in listOf("JKS", "PKCS12")) {
        try {
            val keyStore = KeyStore.getInstance(keyStoreType)
            FileInputStream(storeFile).use {
                keyStore.load(it, storePassword.toCharArray())
            }
            if (!keyStore.containsAlias(keyAlias)) {
                throw GradleException(
                    "Release signing keystore does not contain keyAlias '$keyAlias'.",
                )
            }
            val certificateSubject =
                (keyStore.getCertificate(keyAlias) as? X509Certificate)
                    ?.subjectX500Principal
                    ?.name
                    .orEmpty()
            if (keyAlias.equals("androiddebugkey", ignoreCase = true) ||
                certificateSubject.contains("CN=Android Debug", ignoreCase = true)
            ) {
                throw GradleException(
                    "Release builds cannot use the Android debug certificate.",
                )
            }
            val key = try {
                keyStore.getKey(keyAlias, keyPassword.toCharArray())
            } catch (error: Exception) {
                throw GradleException(
                    "Release signing keyPassword is invalid for keyAlias '$keyAlias'.",
                    error,
                )
            }
            if (key == null) {
                throw GradleException(
                    "Release signing keyAlias '$keyAlias' is not a private key entry.",
                )
            }
            return
        } catch (error: GradleException) {
            throw error
        } catch (error: Exception) {
            loadFailure = error
        }
    }
    throw GradleException(
        "Release signing keystore could not be opened. Check storeFile and storePassword.",
        loadFailure,
    )
}

fun requireValidReleaseSigning() {
    // Explicit compatibility mode for internal APKs that must update the
    // project's historical debug-signed "release" builds. Normal release
    // commands still require a private production keystore.
    if (allowLegacyDebugReleaseSigning) return
    if (!keystorePropertiesFile.isFile) {
        throw GradleException(
            "Release builds require android/key.properties. " +
                "Copy android/key.properties.example and provide a private keystore.",
        )
    }
    if (missingSigningKeys.isNotEmpty()) {
        throw GradleException(
            "android/key.properties is missing required fields: " +
                missingSigningKeys.joinToString(", "),
        )
    }
    if (placeholderSigningKeys.isNotEmpty()) {
        throw GradleException(
            "android/key.properties still contains placeholder values for: " +
                placeholderSigningKeys.joinToString(", "),
        )
    }
    if (releaseStoreFile?.isFile != true) {
        throw GradleException(
            "Release signing storeFile does not point to an existing keystore file.",
        )
    }
    validateReleaseKeyStore(
        storeFile = releaseStoreFile,
        storePassword = releaseSigningValues.getValue("storePassword")!!,
        keyAlias = releaseSigningValues.getValue("keyAlias")!!,
        keyPassword = releaseSigningValues.getValue("keyPassword")!!,
    )
}

if (releaseTaskRequested) {
    requireValidReleaseSigning()
}

val applicationProjectPath = project.path
gradle.taskGraph.whenReady(
    object : Action<TaskExecutionGraph> {
        override fun execute(taskGraph: TaskExecutionGraph) {
        val releaseTaskInGraph = taskGraph.allTasks.any { task ->
            task.project.path == applicationProjectPath &&
                producesReleaseArtifact(task.name)
        }
            if (releaseTaskInGraph && !releaseTaskRequested) {
                requireValidReleaseSigning()
            }
        }
    },
)

android {
    namespace = "app.anime.anime"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "app.anime.anime"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasUsableReleaseSigning) {
            create("release") {
                keyAlias = releaseSigningValues.getValue("keyAlias")!!
                keyPassword = releaseSigningValues.getValue("keyPassword")!!
                storeFile = releaseStoreFile
                storePassword = releaseSigningValues.getValue("storePassword")!!
            }
        }
    }

    buildTypes {
        release {
            if (allowLegacyDebugReleaseSigning) {
                signingConfig = signingConfigs.getByName("debug")
            } else if (hasUsableReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

configurations.configureEach {
    // integration_test brings kxml2, while the CSP WebDAV runtime already
    // supplies the same XmlPull API through xpp3.
    exclude(group = "net.sf.kxml", module = "kxml2")
}

dependencies {
    // Runtime ABI dependencies used by the pinned gao TVBox Spider DEX.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.google.code.gson:gson:2.11.0")
    implementation("com.google.net.cronet:cronet-okhttp:0.1.1")
    implementation("com.github.thegrizzlylabs:sardine-android:0.9")
    implementation("wang.harlon.quickjs:wrapper-android:3.2.3")
    implementation("com.google.zxing:core:3.5.3")
    implementation("com.orhanobut:logger:2.2.0")
    implementation("org.slf4j:slf4j-nop:1.7.36")

    testImplementation("junit:junit:4.13.2")
}

flutter {
    source = "../.."
}
