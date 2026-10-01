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

// 部分插件（如 file_picker 9.x）的 android/build.gradle 硬编码了过低的 compileSdk，
// 而其依赖的 flutter_plugin_android_lifecycle 以 Flutter 的 compileSdkVersion(36) 编译，
// AAR metadata 检查会失败。这里兜底把所有插件子项目的 compileSdk 抬到 36。
// 注意：必须注册在 evaluationDependsOn(":app") 之前，否则对已评估的项目注册 afterEvaluate 会报错。
// 反射调用避免根脚本依赖 AGP 类型；任何异常都静默跳过，不影响正常模块。
subprojects {
    afterEvaluate {
        val androidExt = extensions.findByName("android") ?: return@afterEvaluate
        runCatching {
            val methods = androidExt.javaClass.methods
            val get = methods.firstOrNull { it.name == "getCompileSdk" }
            val set = methods.firstOrNull { it.name == "setCompileSdk" }
            val current = get?.invoke(androidExt) as? Int ?: return@runCatching
            if (current < 36) set?.invoke(androidExt, 36)
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
