# ffmpeg-full

面向 Windows x64 的全功能 FFmpeg 构建脚本。产物使用动态链接，由 `ffmpeg.exe`、`ffprobe.exe`、`ffplay.exe` 和配套 DLL 组成。

## 主要功能

- 基于 FFmpeg master，在 Linux/WSL 中交叉编译。
- 支持常用软编解码器、NVENC/NVDEC、Intel QSV、AMF、Vulkan、OpenCL、字幕和质量评估等功能；NVIDIA 硬解使用原生解码器配合 `-hwaccel cuda`，不构建旧的 `*_cuvid` 解码器。
- 包含 Apple AudioToolbox 的 `aac_at` 编码器，可用 `-c:a aac_at`。Release 将其 Apple Application Support 运行时单独放在 `aac_at_dlc.7z`；使用时把 DLC 中 DLL 解压到 `ffmpeg.exe` 同目录。
- 校验 libaom、SVT-AV1、x264、x265 和 VVenC 参数透传；例如 libaom 使用 `-aom-params tune=iq`。未知参数会直接报错，避免警告后继续编码。
- 支持 VapourSynth 输入；BM3D CUDA 不随压缩包分发，请按 [BM3D CUDA Wiki](https://github.com/Dominic485649/ffmpeg-nvenc-lite/wiki/BM3D%E2%80%90CUDA%E2%80%90%E9%99%8D%E5%99%AA%E6%95%99%E7%A8%8B) 安装 Python 插件。
- 默认针对 x86-64-v3 处理器优化。

## 构建

```bash
chmod +x ffmpeg.sh
./ffmpeg.sh          # 安装/更新工具，更新源码并完整编译
./ffmpeg.sh update   # 只更新源码
./ffmpeg.sh build    # 使用现有源码编译
```

默认复用已可用的 WSL 工具链；需要强制刷新时使用 `TOOLCHAIN_REFRESH=1 ./ffmpeg.sh all`。

产物位于 `full/`。Release 的基础包为 `ffmpeg-full.7z`；仅需 `aac_at` 时再下载 `aac_at_dlc.7z`。

## FFmpegFreeUI 预设

Release 中的 JSON 是 [FFmpegFreeUI](https://github.com/Lake1059/FFmpegFreeUI) v6 预设，放入 `Preset_v6\User` 后读取。NVENC 专用版见 [ffmpeg-nvenc-lite](https://github.com/Dominic485649/ffmpeg-nvenc-lite)，QSV 专用版见 [ffmpeg-qsv-lite](https://github.com/Dominic485649/ffmpeg-qsv-lite)。

> `aac_at_dlc.7z` 包含 Apple 运行时，构建还包含其他 nonfree 组件。FFmpeg 会将二进制标记为 `nonfree and unredistributable`；请自行确认使用与再分发合规性。
