# AVIF HDR 导出说明

RawKit 的 AVIF 导出使用 libavif 提供的 `avifenc` 编码。应用先用 Core Image 渲染 16-bit PNG 中间图，再交给 `avifenc` 输出 10-bit AVIF，并在编码阶段写入 CICP 色彩信令。

## 背景

旧实现使用 Apple ImageIO 写 AVIF。HDR 输出会出现下面的非标准组合：

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

旧实现曾在导出后修补 `colr/nclx` 和 AV1 sequence header。当前实现不再做二进制后处理，改为让 libavif 在编码阶段写入正确 CICP。

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
--yuv 420
--range full
--ignore-profile
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

如果 `MatrixCoefficients` 或 `ffprobe color_space` 仍是 BT.709，说明没有走当前 libavif 参数，或运行时调用到的 `avifenc` 行为不符合预期。
