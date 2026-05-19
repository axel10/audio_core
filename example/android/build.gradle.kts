allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }

    tasks.withType<AbstractCopyTask>().configureEach {
        exclude("**/._*")
        exclude("**/._**")
    }

    tasks.configureEach {
        doFirst {
            try {
                val buildDir = project.layout.buildDirectory.asFile.get()
                if (buildDir.exists()) {
                    buildDir.walkBottomUp().forEach { file ->
                        if (file.name.startsWith("._")) {
                            file.delete()
                        }
                    }
                }
            } catch (e: Exception) {
                // Ignore if build directory provider is not yet available
            }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    if (project.name == "app") {
        val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
        project.layout.buildDirectory.value(newSubprojectBuildDir)
    } else {
        project.layout.buildDirectory.set(file("/tmp/vibe_flow_audio_core_build/${project.name}"))
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
