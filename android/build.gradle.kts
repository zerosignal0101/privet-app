allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // Force SDK/NDK versions on every Android subproject so old plugin pins
    // can't break the build. Done via androidComponents.finalizeDsl, which AGP
    // runs after each plugin's own build script but before it finalizes the
    // variants (so the AAR-metadata check sees the forced values):
    //   - ndkVersion: plugin libraries set `ndkVersion flutter.ndkVersion`
    //     (Flutter's default, 28.2.13676358), so AGP would try to install a
    //     stale/corrupt 28.2 leftover from this SDK dir. The installed NDK is
    //     30.0.14904198 (also used to cross-compile the bundled privetd).
    //   - compileSdk: jni_flutter 1.0.2 pins compileSdk 35 while its dependency
    //     package:jni ships an AAR requiring API 36, so the AAR-metadata check
    //     fails unless the subproject is raised to 36.
    plugins.withId("com.android.library") {
        (extensions.findByName("androidComponents")
            as? com.android.build.api.variant.AndroidComponentsExtension<*, *, *>)?.let { ac ->
            ac.finalizeDsl { dsl ->
                (dsl as? com.android.build.api.dsl.LibraryExtension)?.let { lib ->
                    lib.ndkVersion = "30.0.14904198"
                    if ((lib.compileSdk ?: 0) < 36) {
                        lib.compileSdk = 36
                    }
                }
            }
        }
    }
    plugins.withId("com.android.application") {
        (extensions.findByName("androidComponents")
            as? com.android.build.api.variant.AndroidComponentsExtension<*, *, *>)?.let { ac ->
            ac.finalizeDsl { dsl ->
                (dsl as? com.android.build.api.dsl.ApplicationExtension)?.let { app ->
                    app.ndkVersion = "30.0.14904198"
                }
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
