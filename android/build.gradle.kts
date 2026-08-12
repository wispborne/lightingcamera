allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// androidx.camera:camera-core 1.6.0 only lists androidx.concurrent:concurrent-futures
// as a runtime dependency, but its SurfaceRequest class has an annotation that points
// at CallbackToFutureAdapter from that library. javac needs the class to read the
// annotation, so compiling the camera plugin fails with "Cannot attach type
// annotations". Putting the library on the camera plugin's compile path fixes it.
subprojects {
    if (name == "camera_android_camerax") {
        afterEvaluate {
            dependencies.add("implementation", "androidx.concurrent:concurrent-futures:1.2.0")
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
