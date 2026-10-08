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
}

// file_picker (and some other plugins) still advertise compileSdk 34 while
// flutter_plugin_android_lifecycle needs ≥ 36. Raise every Android module.
subprojects {
    afterEvaluate {
        val android = extensions.findByName("android") ?: return@afterEvaluate
        val methods = android.javaClass.methods
        methods
            .firstOrNull {
                it.name == "setCompileSdk" &&
                    it.parameterCount == 1 &&
                    it.parameterTypes[0] == Int::class.javaPrimitiveType
            }?.invoke(android, 36)
            ?: methods
                .firstOrNull {
                    it.name == "setCompileSdkVersion" &&
                        it.parameterCount == 1 &&
                        it.parameterTypes[0] == Int::class.javaPrimitiveType
                }?.invoke(android, 36)
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
