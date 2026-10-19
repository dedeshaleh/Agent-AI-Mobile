allprojects {
    repositories {
        google()
        mavenCentral()
        // AARs bundled with the Unity export (unity-classes.jar etc.).
        val unityLibs = rootProject.file("unityLibrary/libs")
        if (unityLibs.exists()) {
            flatDir { dirs(unityLibs) }
        }
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
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
