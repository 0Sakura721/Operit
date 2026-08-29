# 适配 armeabi-v7a（32 位 ARM）

本文件记录为 Operit 增加 32 位 ARM（`armeabi-v7a`）支持的改动、构建方法以及已知边界。

## 背景

- `main` 分支一直只编译 `arm64-v8a`（每个 `app`/`llm`/`quickjs`/`avator`/`terminal` 模块的
  `abiFilters.addAll(listOf("arm64-v8a"))`）。
- 历史版本其实是双 ABI：`v1.3.0` 的 `app/build.gradle.kts` 是
  `abiFilters.addAll(listOf("armeabi-v7a", "arm64-v8a"))`；`v1.6.0` 之后才改成 `arm64-v8a` 单 ABI。
- 因此工程自身的 native 源码（sherpa-ncnn、MNN、llama.cpp、WAMR、quickjs、dragonbones、ufbx、saba、
  bullet3、streamnative、pty）都**能从源码为 `armeabi-v7a` 编译**，并未依赖 ARMv8-only 特性。

## 改动

### ABI 由 Gradle 属性控制（默认保持 arm64-only）

在 `gradle.properties` 新增：

```properties
operit.abis=arm64-v8a
```

每个 native 模块（`app`、`llm/mnn`、`llm/llama`、`quickjs`、`avator/{mmd,fbx,dragonbones}`、
`terminal`）从根项目读取 `operit.abis` 并 `abiFilters.addAll(...)`，同时给 CMake 传入
`-DANDROID_ARM_NEON=TRUE`（armeabi-v7a 下开启 NEON）。默认值仍是 `arm64-v8a`，**不改变原有
arm64 CI 的行为**。

要出双 ABI/32 位包，构建时传：

```bash
./gradlew assembleDebug -Poperit.abis=armeabi-v7a,arm64-v8a
```

### 外部预编译库校验

`app/build.gradle.kts` 的 `verifyExternallyBuiltNativeLibraries` 现在按 `operit.abis` 逐一校验：
- `src/main/jniLibs/<abi>/liboperit_ripgrep.so`
- `libs/ffmpeg-kit-local.aar` 内对应 ABI 的 FFmpegKit `jni/<abi>/*.so`

### 构建脚本

- `tools/native_ripgrep/build_native_ripgrep.ps1`：默认 `Targets` 改为
  `aarch64-linux-android, armv7-linux-androideabi`。
- `tools/ffmpeg/build_ffmpeg_kit_wsl.sh`：不再 `disable_arch arm-v7a-neon` / `--disable-arm-v7a-neon`，
  因此会同时产出 `arm64-v8a` 与 `armeabi-v7a`；`OPERIT_PROXY_HOST` 为空时不再设置代理（可在
  Linux CI runner 直接运行）。
- **重要**：上游 `arthanecia/ffmpeg-kit` 仓库已删除，原脚本引用的源不可用。改用保留了同一套
  `android.sh`/`scripts/` 接口且带 16KB 页对齐的镜像
  [CodeShipping/ffmpeg-kit-android-16KB](https://github.com/CodeShipping/ffmpeg-kit-android-16KB)。
  构建前把该仓库克隆到 `$FFMPEG_KIT_DIR` 再执行本脚本即可。

### 新增构建 workflow

`.github/workflows/android-build-armv7.yml`（手动触发）：

- 输入 `abis`（默认 `armeabi-v7a,arm64-v8a`）、`build_ffmpeg`（默认开）、`extra_armv7_dir`。
- 从源码编 `liboperit_ripgrep.so`（各 ABI）、从源码编 `ffmpeg-kit` AAR（各 ABI，源为
  `CodeShipping/ffmpeg-kit-android-16KB`）。
- checkout 后对 `terminal` 子模块的 `build.gradle.kts` 打补丁，使其也遵循根项目的 `operit.abis`。
- 下载项目外部依赖归档（`subpack.zip` / `libs.zip` / `jniLibs.zip`），构建 web-chat、ToolPkg，
  最后运行 `./gradlew <task> -Poperit.abis=<abis>` 并上传 APK。

## 模块级 v7a 状态

| 模块 | 来源 | v7a |
| --- | --- | --- |
| llama.cpp（llm/llama） | 源码（固定 commit） | 可编译（ggml 走 ARMv7 NEON/scalar） |
| MNN + LLM（llm/mnn） | 源码（固定 commit）+ KleidiAI 仅 aarch64 | 可编译（armv7 用 arm32 汇编 + NEON） |
| sherpa-ncnn 语音识别（app cpp） | 源码 | 可编译（v7a STT 可用） |
| WAMR / toolpkgwasm（app cpp） | 源码 | 可编译（`armeabi-v7a -> ARMV7A`） |
| streamnative（app cpp） | 源码 | 可编译 |
| quickjs | 源码 | 可编译 |
| dragonbones / ufbx / saba / bullet3 | 源码 | 可编译 |
| pty（terminal） | 源码 | 可编译 |
| operit_ripgrep | Rust（cargo-ndk，脚本已支持 armv7） | 可编译 |
| ffmpeg-kit AAR | 源码（CodeShipping 镜像） | 可编译（已启用 arm-v7a-neon） |
| libsherpa-mnn-jni.so | 预编译（arm64 only） | **不影响**：`SherpaMnnSpeechProvider` 是死代码，运行时不会加载 |
| terminal 的 `libbash/libbusybox/liboperit_proot/liboperit_loader/libsudo.so` | 预编译（arm64 only） | **缺失**：任何历史版本都没出过 v7a |

## 已知边界

- **proot 终端（shell 工具）在 v7a 上不可用**。这 5 个 `.so` 在工程与任何历史 release 中都只有
  `arm64-v8a`，也没有可用的 v7a 源码路径。`TerminalManager` 是懒加载，因此 v7a 上 app 不会因此崩溃，
  只有「终端 / 依赖 shell 的命令」这两类功能不可用。若需在 v7a 上启用，需要自行准备对应 32 位
  `bash / busybox / proot / loader / sudo` 并放置到 `terminal/src/main/jniLibs/armeabi-v7a/`，再通过
  workflow 的 `extra_armv7_dir` 注入。
- 3D 头像（`filament` / GLES3 / `mmd` / `fbx`）与 ffmpeg 依赖的设备 GPU/DSP 能力随设备不同，但构建与
  安装不受影响。

## 验证（在具备 Android SDK/NDK 的环境或 GitHub Actions 中）

```bash
chmod +x ./gradlew
./gradlew assembleDebug -Poperit.abis=armeabi-v7a,arm64-v8a --stacktrace
```

产物：`app/build/outputs/apk/debug/app-debug.apk`。可用
`unzip -l app-debug.apk | grep '^  lib/armeabi-v7a/'` 检查 32 位 native 已打入。
