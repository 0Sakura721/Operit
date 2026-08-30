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

### terminal 子模块原生支持多 ABI

`terminal/build.gradle.kts` 的 `abiFilters` 不再硬编码 `arm64-v8a`，改为从根项目读取
`operit.abis` 属性，与其他模块保持一致。CI 中不再需要对 terminal 子模块打 sed 补丁。

### TerminalManager 按设备架构选择 rootfs

`TerminalManager.kt` 和 `CacheManager.kt` 不再硬编码 `ubuntu-noble-aarch64-pd-v4.18.0.tar.xz`，
改为在运行时通过 `Build.SUPPORTED_ABIS` 检测设备架构，选择对应的 rootfs：

| 设备 ABI | Ubuntu 架构 | rootfs 文件名 |
| --- | --- | --- |
| arm64-v8a | aarch64 | `ubuntu-noble-aarch64-pd-v4.18.0.tar.xz`（已内置） |
| armeabi-v7a | armhf | `ubuntu-noble-armhf-pd-v4.18.0.tar.xz`（需构建/下载） |
| x86_64 | amd64 | `ubuntu-noble-amd64-pd-v4.18.0.tar.xz` |
| x86 | i386 | `ubuntu-noble-i386-pd-v4.18.0.tar.xz` |

### 外部预编译库校验

`app/build.gradle.kts` 的 `verifyExternallyBuiltNativeLibraries` 现在按 `operit.abis` 逐一校验：

- `src/main/jniLibs/<abi>/liboperit_ripgrep.so`
- `libs/ffmpeg-kit-local.aar` 内对应 ABI 的 FFmpegKit `jni/<abi>/*.so`

**所有启用的 ABI 都必须有对应的 ffmpeg 原生库**，缺失会导致构建失败（不再是仅警告）。

### 终端原生库构建脚本

新增 `tools/terminal/build_terminal_libs.sh`，从源码为指定 ABI 构建终端所需的 5 个原生库：

| 库 | 来源 | 类型 |
| --- | --- | --- |
| `libbash.so` | GNU Bash 5.2 | 静态链接可执行文件 |
| `libbusybox.so` | BusyBox 1.36.1 | 静态链接可执行文件 |
| `liboperit_proot.so` | termux/proot | 动态链接（Android Bionic） |
| `liboperit_loader.so` | proot loader | 静态、无 libc、位置无关 |
| `libsudo.so` | 文本脚本 | 架构无关（内容 `$@`） |

> **注意**：这些 `.so` 文件实际上是独立可执行文件，使用 `.so` 扩展名只是为了让 Android 将其
> 打包到 APK 的 `lib/` 目录中。它们不会在编译时被链接。

用法：

```bash
export ANDROID_NDK_HOME=/path/to/ndk
./tools/terminal/build_terminal_libs.sh armeabi-v7a
# 或多 ABI：
./tools/terminal/build_terminal_libs.sh armeabi-v7a,arm64-v8a
```

产物会自动放置到 `terminal/src/main/jniLibs/<abi>/`。

### Ubuntu armhf rootfs 构建脚本

新增 `tools/terminal/build_ubuntu_armhf_rootfs.sh`，使用 debootstrap + qemu-user-static 构建
Ubuntu 24.04 armhf rootfs，产物为 `terminal/src/main/assets/ubuntu-noble-armhf-pd-v4.18.0.tar.xz`。

CI 中会优先尝试下载预构建的 Ubuntu Base armhf rootfs，失败时再从源码构建。

### ffmpeg 构建脚本修复

`tools/ffmpeg/build_ffmpeg_kit_wsl.sh` 之前虽然注释说支持双 ABI，但实际代码中仍有
`disable_arch arm-v7a` 和 `--disable-arm-v7a`，导致只产出 arm64。现已修复为：

- `enable_arch arm-v7a-neon`（启用带 NEON 的 32 位 ARM）
- `--enable-arm-v7a-neon`

`OPERIT_PROXY_HOST` 为空时不再设置代理（可在 Linux CI runner 直接运行）。

**重要**：上游 `arthanecia/ffmpeg-kit` 仓库已删除，原脚本引用的源不可用。改用保留了同一套
`android.sh`/`scripts/` 接口且带 16KB 页对齐的镜像
[CodeShipping/ffmpeg-kit-android-16KB](https://github.com/CodeShipping/ffmpeg-kit-android-16KB)。
构建前把该仓库克隆到 `$FFMPEG_KIT_DIR` 再执行本脚本即可。

### ripgrep 构建脚本

`tools/native_ripgrep/build_native_ripgrep.ps1`：默认 `Targets` 改为
`aarch64-linux-android, armv7-linux-androideabi`。

### TLS 编译选项按 ABI 区分

`-fno-emulated-tls` 是 aarch64 专用优化，在 armeabi-v7a 上会导致链接错误
`undefined symbol: __tls_get_addr`。以下模块的 CMakeLists.txt 已改为按 ABI 条件设置：

- `avator/mmd/CMakeLists.txt`
- `llm/llama/CMakeLists.txt`
- `llm/mnn/CMakeLists.txt`

对应的 `build.gradle.kts` 中移除了全局的 `-fno-emulated-tls` cppFlags。

### llamafile 在 armeabi-v7a 上禁用

llama.cpp 的 llamafile 功能使用了 aarch64 专用的 fp16 NEON 内联汇编，在 32 位 ARM 上无法编译。
在 armeabi-v7a 构建中禁用 llamafile（不影响普通 GGUF 推理）。

### CI workflow 更新

`.github/workflows/android-build-armv7.yml`（手动触发）：

- 输入 `abis`（默认 `armeabi-v7a,arm64-v8a`）、`build_ffmpeg`（默认开）、`extra_armv7_dir`（可选预编译库覆盖）。
- 从源码编 `liboperit_ripgrep.so`（各 ABI）。
- 从源码编终端原生库（bash/busybox/proot/loader/sudo），仅针对非内置 ABI（arm64 已内置）。
- 下载或构建 armhf Ubuntu rootfs（当启用 armeabi-v7a 时）。
- 从源码编 `ffmpeg-kit` AAR（各 ABI，源为 `CodeShipping/ffmpeg-kit-android-16KB`）。
- 不再对 terminal 子模块打 sed 补丁（源码已原生支持 `operit.abis`）。
- 下载项目外部依赖归档（`subpack.zip` / `libs.zip` / `jniLibs.zip`），构建 web-chat、ToolPkg，
  最后运行 `./gradlew <task> -Poperit.abis=<abis>` 并上传 APK。

## 模块级 v7a 状态

| 模块 | 来源 | v7a |
| --- | --- | --- |
| llama.cpp（llm/llama） | 源码（固定 commit） | 可编译（ggml 走 ARMv7 NEON/scalar，llamafile 禁用） |
| MNN + LLM（llm/mnn） | 源码（固定 commit）+ KleidiAI 仅 aarch64 | 可编译（armv7 用 arm32 汇编 + NEON） |
| sherpa-ncnn 语音识别（app cpp） | 源码 | 可编译（v7a STT 可用） |
| WAMR / toolpkgwasm（app cpp） | 源码 | 可编译（`armeabi-v7a -> ARMV7A`） |
| streamnative（app cpp） | 源码 | 可编译 |
| quickjs | 源码 | 可编译 |
| dragonbones / ufbx / saba / bullet3 | 源码 | 可编译 |
| pty（terminal） | 源码 | 可编译 |
| operit_ripgrep | Rust（cargo-ndk，脚本已支持 armv7） | 可编译 |
| ffmpeg-kit AAR | 源码（CodeShipping 镜像） | 可编译（已启用 arm-v7a-neon） |
| terminal 原生库（bash/busybox/proot/loader/sudo） | 源码（`build_terminal_libs.sh`） | 可编译（CI 自动构建） |
| Ubuntu rootfs | debootstrap（`build_ubuntu_armhf_rootfs.sh`） | 可构建（armhf） |
| libsherpa-mnn-jni.so | 预编译（arm64 only） | **不影响**：`SherpaMnnSpeechProvider` 是死代码，运行时不会加载 |

## 已知边界

- **32 位设备内存限制**：armeabi-v7a 设备通常 RAM 较小（2-4GB），且单个 32 位进程的虚拟地址空间
  只有 ~3GB。大模型（如 7B GGUF）可能因地址空间不足无法加载。这属于硬件限制，不是构建问题。
- **3D 头像**（`filament` / GLES3 / `mmd` / `fbx`）与 ffmpeg 依赖的设备 GPU/DSP 能力随设备不同，
  但构建与安装不受影响。
- **proot 性能**：32 位设备上 proot 的性能通常低于 64 位设备，因为 32 位 ARM 的 ptrace 开销更大
  且没有 ARMv8 的某些优化。

## 验证（在具备 Android SDK/NDK 的环境或 GitHub Actions 中）

```bash
chmod +x ./gradlew
./gradlew assembleDebug -Poperit.abis=armeabi-v7a,arm64-v8a --stacktrace
```

产物：`app/build/outputs/apk/debug/app-debug.apk`。可用
`unzip -l app-debug.apk | grep '^  lib/armeabi-v7a/'` 检查 32 位 native 已打入。

验证终端库：

```bash
file terminal/src/main/jniLibs/armeabi-v7a/libbusybox.so
# 应输出: ELF 32-bit LSB executable, ARM, EABI5 version 1 (SYSV), statically linked
```

验证 rootfs：

```bash
tar -xOf terminal/src/main/assets/ubuntu-noble-armhf-pd-v4.18.0.tar.xz bin/bash | file -
# 应输出: ELF 32-bit LSB executable, ARM, EABI5 version 1 (SYSV), dynamically linked
```
