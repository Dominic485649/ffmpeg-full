# FFmpeg Full · Windows x64

面向视频转码、字幕渲染、音频处理和画质评估的 Windows x64 FFmpeg 构建，提供丰富的软件编解码器与 NVIDIA、Intel、AMD 硬件处理接口。

**程序组成：`ffmpeg.exe`、`ffprobe.exe`、`ffplay.exe` 及配套 DLL。**

[下载 Release](https://github.com/Dominic485649/ffmpeg-full/releases) · [NVENC Lite](https://github.com/Dominic485649/ffmpeg-nvenc-lite) · [QSV Lite](https://github.com/Dominic485649/ffmpeg-qsv-lite)

## 版本选择

| 版本 | 主要用途 | 程序组成 |
|---|---|---|
| **Full（本仓库）** | 软件编码、硬件转码、字幕、图像、音频、网络与 VMAF | 三个 EXE + 配套 DLL |
| [NVENC Lite](https://github.com/Dominic485649/ffmpeg-nvenc-lite) | NVIDIA HEVC/AV1 编码、NVDEC 与 CUDA 滤镜 | 单个 `ffmpeg.exe` |
| [QSV Lite](https://github.com/Dominic485649/ffmpeg-qsv-lite) | Intel HEVC/AV1 编码、QSV 滤镜与现代 D3D 硬解 | 单个 `ffmpeg.exe` |

## 主要功能

| 类别 | 提供的能力 |
|---|---|
| 软件视频编码 | x264 **8-bit**、x265 **8/10-bit**、libaom、SVT-AV1、libvpx、VVenC 等 |
| 视频解码 | FFmpeg 原生常用解码器，包含原生 VVC、`avs` / `cavs`（AVS1） |
| NVIDIA | NVENC/NVDEC、CUDA；`scale_cuda`、`yadif_cuda`、`bwdif_cuda`、`overlay_cuda` 等滤镜 |
| Intel | oneVPL/QSV；`vpp_qsv`、`scale_qsv`、去隔行、叠加与拼接滤镜 |
| AMD / Windows 图形接口 | AMF 编码与滤镜；现代 D3D11/D3D12 设备和硬解路径 |
| 图像与色彩 | PNG/APNG、WebP、JPEG XL、JPEG 2000；libplacebo、Vulkan、zimg、LCMS/ICC |
| 字体与字幕 | libass、FreeType、HarfBuzz、FriBidi、Fontconfig；`subtitles`、`drawtext` |
| 画质评估 | CPU `libvmaf`，内置 **17 个官方模型**；PSNR、SSIM、XPSNR 等 |
| 音频 | 原生 AAC（含 NMR 参数）、libopus、MP3、Vorbis、FLAC；SoXR 重采样、Rubber Band 变速变调 |
| 空间音频处理 | libmysofa / `sofalizer`，读取 SOFA HRTF 并用于双耳渲染 |
| 输入与网络 | AviSynth、常用封装；HTTP(S)、RTMP(S)、SRT、RIST、SFTP、ZMQ 等协议 |
| 元数据与比特流处理 | HEVC HDR Vivid T.35 元数据解析、上游 Dolby Vision 相关解析、`dovi_rpu` / `dovi_split` |

硬件功能的可用范围由 GPU 型号、驱动、素材格式与相应编码器共同决定。

## 下载与安装

1. 在 [Releases](https://github.com/Dominic485649/ffmpeg-full/releases) 选择版本并查看该版本说明。
2. 使用该版本提供的 `*-setup.exe` 时，可运行 7-Zip SFX 安装器，选择有写入权限的目录，并决定是否加入**当前用户 PATH**。
3. 便携使用时，可用 7-Zip 提取整套 EXE/DLL，并按需手动设置 PATH。
4. Full 使用动态链接，运行与升级时请保持整套 EXE/DLL 的版本一致；建议使用独立目录存放每个版本。
5. PATH 设置完成后，重新打开终端。

运行环境为 **64 位 Windows**，CPU 须满足 **x86-64-v3（含 AVX2 等指令）**。硬件加速需要相应 GPU 与驱动，libplacebo 需要可用的 Vulkan 驱动。

以下示例假定 `ffmpeg.exe` 已加入 PATH，也可使用完整路径。

```bash
ffmpeg.exe -version
```

查询实际编码器、滤镜和协议：

```bash
ffmpeg.exe -encoders
```

```bash
ffmpeg.exe -filters
```

```bash
ffmpeg.exe -protocols
```

## 常用示例

### H.264 / 8-bit 软件编码

```bash
ffmpeg.exe -i input.mkv -map 0:v:0 -map "0:a:0?" -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -c:a aac -b:a 192k output-h264.mp4
```

### HEVC / 10-bit 软件编码

```bash
ffmpeg.exe -i input.mkv -map 0:v:0 -map "0:a:0?" -c:v libx265 -preset slow -crf 22 -pix_fmt yuv420p10le -c:a aac -b:a 192k output-hevc.mkv
```

HDR 转码还需根据源素材正确配置色彩信息和处理链。

### ASS 字幕烧录

```bash
ffmpeg.exe -i input.mkv -vf "subtitles=captions.ass" -c:v libx264 -crf 20 -pix_fmt yuv420p -c:a copy output-subtitled.mkv
```

### SoXR 重采样与 Opus 编码

```bash
ffmpeg.exe -i input.wav -vn -af "aresample=48000:resampler=soxr" -c:a libopus -b:a 128k -f ogg output.ogg
```

### 原生 AAC / NMR

```bash
ffmpeg.exe -i input.wav -vn -c:a aac -aac_coder nmr -aac_nmr_speed 0 -b:a 192k output.m4a
```

NVIDIA 与 Intel 硬件处理示例见 [NVENC Lite README](https://github.com/Dominic485649/ffmpeg-nvenc-lite#readme) 和 [QSV Lite README](https://github.com/Dominic485649/ffmpeg-qsv-lite#readme)，Full 同样提供这些主要处理链。

## CPU VMAF

内置 **17 个官方模型**，可直接通过模型名称调用：

| 分组 | 模型名称 |
|---|---|
| 默认 SDR | `vmaf_v0.6.1` |
| SDR v1 | `vmaf_v1.0.16_3d0h`、`vmaf_v1.0.16_3d0h_2160`、`vmaf_v1.0.16_5d0h`、`vmaf_v1.0.16_1d5h_2160` |
| SDR v1 / HFR | `vmaf_v1.0.16_hfr_3d0h`、`vmaf_v1.0.16_hfr_3d0h_2160`、`vmaf_v1.0.16_hfr_5d0h`、`vmaf_v1.0.16_hfr_1d5h_2160` |
| HDR v1 | `hdr_vmaf_v1.1.8_3d0h`、`hdr_vmaf_v1.1.8_3d0h_2160`、`hdr_vmaf_v1.1.8_5d0h`、`hdr_vmaf_v1.1.8_1d5h_2160` |
| HDR v1 / HFR | `hdr_vmaf_v1.1.8_hfr_3d0h`、`hdr_vmaf_v1.1.8_hfr_3d0h_2160`、`hdr_vmaf_v1.1.8_hfr_5d0h`、`hdr_vmaf_v1.1.8_hfr_1d5h_2160` |

默认模型为 `vmaf_v0.6.1`。v1、HDR 与 HFR 模型通过 `model=version=...` 显式选择；按内容帧率、显示分辨率和观看条件选用对应模型。

`libvmaf` 使用 CPU 软件帧。使用硬件解码时，先按输入位深正确下载硬件帧。比较顺序为**失真视频在前、参考视频在后**，两路画面、帧、尺寸与时间戳需要对齐。

### SDR v1 评分

```bash
ffmpeg.exe -i distorted.mkv -i reference.mkv -filter_complex "[0:v]setpts=PTS-STARTPTS[dist];[1:v]setpts=PTS-STARTPTS[ref];[dist][ref]libvmaf=model=version=vmaf_v1.0.16_3d0h:log_fmt=json:log_path=vmaf.json" -an -f null -
```

### HDR10 / PQ 评分

HDR 评分使用官方 HDR v1 模型，并开启 `independent_color=1`，让参考与失真输入分别传递和协商色彩信息。

两路输入都需要完整、正确的 **range / primaries / transfer / matrix** 标签。下面示例用于已经正确标记的 BT.2020、SMPTE ST 2084（PQ）、BT.2020 non-constant-luminance 10-bit HDR10 素材：

```bash
ffmpeg.exe -i distorted-hdr10.mkv -i reference-hdr10.mkv -filter_complex "[0:v]format=yuv420p10le,setpts=PTS-STARTPTS[dist];[1:v]format=yuv420p10le,setpts=PTS-STARTPTS[ref];[dist][ref]libvmaf=independent_color=1:model=version=hdr_vmaf_v1.1.8_3d0h:log_fmt=json:log_path=hdr-vmaf.json" -an -f null -
```

16-bit 平面素材可使用对应的 `yuv420p16le` 路径。评分时应保持素材真实的像素含义与色彩标签；`setparams` 用于设置标签，实际色彩转换应使用相应转换滤镜。

## 从源码构建

在 Linux/WSL2 中交叉编译 Windows x64 程序。完整构建集合包括根 `ffmpeg.sh`、`scripts/`、`shared-patches/` 与 `build-manifests/write_manifest.py`，应保持配套使用。

准备工具链与构建工具（安装/更新阶段会联网，部分操作需要提权）：

```bash
./ffmpeg.sh tool
```

更新本配置的依赖源码：

```bash
./ffmpeg.sh update
```

使用现有源码构建：

```bash
./ffmpeg.sh build
```

工具链已就绪时，`TOOLCHAIN_REFRESH=0` 可用于在 `tool` 阶段复用现有工具。不带参数或使用 `all` 的完整流程为 `tool → update → build`。

| 用途 | 默认路径 |
|---|---|
| 依赖源码 | `sources/` |
| 依赖安装前缀 | `bin/` |
| 构建与内容缓存 | `build/` |
| 运行文件 | `full/` |

在其他依赖已准备好的环境中，选择性构建 x265 与 FFmpeg：

```bash
./ffmpeg.sh build --only x265,ffmpeg
```

`--only` 运行显式列出的阶段；常规构建可通过完整 `build` 自动核验各阶段缓存。缓存依据源码、配置、工具链、依赖和产物内容判定，构建清单记录实际提交、参数及文件哈希。FFmpeg 默认跟踪 `master`，各依赖按自身更新策略选择版本。

## FFmpegFreeUI 预设

若 Release 附带 JSON，可作为 [FFmpegFreeUI](https://github.com/Lake1059/FFmpegFreeUI) v6 用户预设放入 `Preset_v6\User`。预设作为可选独立附件提供，使用前请确认编码器、滤镜与本机路径匹配。

## 实测与许可证

2026-11-03 的本地产物已通过隔离运行和 DLL 依赖检查，并完成以下实测：

- RTX 4060 Laptop：CUDA 缩放、HEVC/AV1 NVENC 编码。
- Intel Arc：QSV VPP、HEVC/AV1 编码。
- 现代 D3D11/D3D12 HEVC 硬解、硬件帧下载和 libplacebo/Vulkan 处理。
- PNG/APNG、SOFA HRTF、VVenC 编码与原生 VVC 解码。
- x264 8-bit、x265 8/10-bit、SoXR、Opus 与 AAC。
- 全部 17 个 VMAF 模型；HDR-VMAF 与独立官方 CLI 交叉评分。

各版本的程序身份、文件体积与验证信息见对应 Release。

自有脚本与文档采用 [MIT License](https://github.com/Dominic485649/ffmpeg-full/blob/main/LICENSE)。本配置的 FFmpeg 许可证标识为 **`nonfree and unredistributable`**；FFmpeg、外部库、驱动与安装器组件适用各自许可证，使用与分发须满足相应许可要求。
