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
    // can't break the build:
    //   - ndkVersion: plugin libraries set `ndkVersion flutter.ndkVersion`
    //     (Flutter's default, 28.2.13676358), so AGP would try to install a
    //     stale/corrupt 28.2 leftover from this SDK dir. The installed NDK is
    //     30.0.14904198 (also used to cross-compile the bundled privetd).
    //   - compileSdk: some plugins pin old compileSdk (e.g. file_picker 9.2.3
    //     pins 34) while dependencies require 36.
    // Registered here (before evaluationDependsOn below triggers :app's
    // evaluation) and applied in afterEvaluate so it runs after each plugin's
    // own assignment.
    if (!project.state.executed) {
        afterEvaluate {
            if (pluginManager.hasPlugin("com.android.library")) {
                extensions.configure<com.android.build.api.dsl.LibraryExtension> {
                    ndkVersion = "30.0.14904198"
                    compileSdk = 36
                }
            }
            if (pluginManager.hasPlugin("com.android.application")) {
                extensions.configure<com.android.build.api.dsl.ApplicationExtension> {
                    ndkVersion = "30.0.14904198"
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
