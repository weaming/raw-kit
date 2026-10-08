# AVIF HDR 导出说明

RawKit 的 AVIF 导出使用 libavif 提供的 `avifenc` 编码。应用先用 Core Image 渲染 16-bit PNG 中间图，再交给 `avifenc` 输出 10-bit AVIF，并在编码阶段写入 CICP 色彩信令。

## 背景

旧实现使用 Apple ImageIO 写 AVIF。HDR 输出曾出现下面的组合：

```text
ColorPrimaries          : BT.2020
TransferCharacteristics : PQ 或 HLG
MatrixCoefficients      : BT.709
```

对 BT.2020 + PQ/HLG HDR AVIF，更稳定的组合是：

```text
PQ  HDR : primaries=9 / transfer=16 / matrix=9
HLG HDR : primaries=9 / transfer=18 / matrix=9
```

矩阵编号必须与编码时实际使用的 RGB/YCbCr 转换一致，不能仅凭色域判断组合非法，也不能只改标签来改变矩阵。当前实现让 libavif 在编码阶段配置 CICP，保留生成的容器和 AV1 sequence header。

不再补写推算的 `clli`/`mdcv`：相对线性亮度不能统一乘以 100 当作 PQ/HLG 绝对亮度；输出色域和图片峰值也不代表母版显示设备参数。没有可靠来源时省略这些可选属性。

PNG 同时包含 cICP 和 ICC 时，libavif 会优先读取 cICP，未必复制 ICC。因此应用显式导出目标色彩空间的 ICC，并通过 `--icc` 传入，与 CICP 一起写入 AVIF。

## 导出路径

核心流程在 `RawKit/Services/ImageExporter.swift`：

```text
CIImage 调整尺寸
  ↓
prepareImageForExport
  ↓
按输出预设选择输出色彩空间
  ↓
Core Image 写 16-bit PNG 中间图
  ↓
avifenc 写 10-bit AVIF
```

`avifenc` 查找顺序：

- app bundle resource `avifenc`
- app 可执行文件同目录 `avifenc`
- `/opt/homebrew/bin/avifenc`
- `/usr/local/bin/avifenc`
- 当前进程 `PATH`

缺少工具时会提示安装 libavif：

```text
brew install libavif
```

## 编码参数

当前 `avifenc` 参数：

```text
--jobs all
--speed 6
--qcolor <导出质量 1...100>
--depth 10
--yuv 444
--range full
--icc <输出色彩空间的 ICC 文件>
--cicp <按输出预设生成>
```

CICP 对应关系：

```text
SDR sRGB          : 1/13/1
Display P3 SDR    : 12/13/1
Display P3 HLG HDR: 12/18/1
Display P3 PQ HDR : 12/16/1
Rec.2020 HLG HDR  : 9/18/9
Rec.2020 PQ HDR   : 9/16/9
```

## 验证方法

导出后运行：

```fish
fish scripts/check-avif.fish /path/to/file.avif
```

PQ AVIF 预期：

```text
ColorPrimaries          : BT.2020, BT.2100
TransferCharacteristics : SMPTE ST 2084, ITU BT.2100 PQ
MatrixCoefficients      : BT.2020 non-constant luminance, BT.2100 YCbCr
VideoFullRangeFlag      : Full
ImagePixelDepth         : 10 10 10

ffprobe:
color_space=bt2020nc
color_transfer=smpte2084
color_primaries=bt2020
```

HLG AVIF 预期：

```text
ColorPrimaries          : BT.2020, BT.2100
TransferCharacteristics : BT.2100 HLG, ARIB STD-B67
MatrixCoefficients      : BT.2020 non-constant luminance, BT.2100 YCbCr
VideoFullRangeFlag      : Full
ImagePixelDepth         : 10 10 10

ffprobe:
color_space=bt2020nc
color_transfer=arib-std-b67
color_primaries=bt2020
```

以上为 Rec.2020 预设的预期值；P3 AVIF 使用编码阶段配置的 BT.709 矩阵。HEIF 保留 Apple 编码器实际选择的矩阵（实测 HDR 输出可能为 BT.709 或 BT.2020），不能用 AVIF 的预期值覆盖 HEIF。

`RawKitTests/HDRExportTests.swift` 检查所有可选 HEIF/AVIF 预设的 box 边界、主图属性关联、`iloc` 数据范围和 10-bit 声明，提取裸码流后用 ffprobe 对比 CICP，并通过 FFmpeg 独立解码比较亮度阶梯和彩色色块。测试需要 ffmpeg 和 libavif；缺少依赖时明确标记跳过。
