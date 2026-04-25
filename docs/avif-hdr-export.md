# AVIF HDR 导出修复说明

## 背景

RawKit 的 AVIF HDR 导出目标是使用 Apple ImageIO 完成编码，同时让导出的 AVIF 在 Chrome 中按 HDR 图片显示。

此前导出的 AVIF 在 Quick Look 中有 HDR 效果，但 Chrome 中可能没有 HDR 效果，甚至出现白屏。检查后发现关键问题集中在 AVIF 色彩信令：

```text
ColorPrimaries          : BT.2020
TransferCharacteristics : PQ 或 HLG
MatrixCoefficients      : BT.709
```

这是非标准的 HDR 组合。对 BT.2020 + PQ/HLG HDR 图片，更常见、Chrome/libavif 路径更稳定的组合是：

```text
PQ  HDR : primaries=9 / transfer=16 / matrix=9
HLG HDR : primaries=9 / transfer=18 / matrix=9
```

其中：

- `primaries=9` 表示 BT.2020 色域
- `transfer=16` 表示 SMPTE ST 2084，也就是 PQ
- `transfer=18` 表示 ARIB STD-B67，也就是 HLG
- `matrix=9` 表示 BT.2020 non-constant luminance YCbCr
- `matrix=1` 表示 BT.709 YCbCr

Apple ImageIO 能写出 BT.2020 + PQ/HLG + 10-bit AVIF，但当前输出会把 matrix 写成 BT.709。Chrome 对这个组合不稳定，因此需要修正导出后的色彩信令。

## 导出路径

AVIF 导出仍然使用 Apple ImageIO，不调用外部编码器。

核心路径在 `RawKit/Services/ImageExporter.swift`：

```swift
CGImageDestinationCreateWithURL(
    url as CFURL,
    "public.avif" as CFString,
    1,
    nil
)
```

HDR AVIF 导出时使用：

```swift
let outputImage = normalizedHDRImage(
    makeOpaqueImageForJPEG(image),
    targetHeadroom: targetHeadroom
)

let cgImage = context.createCGImage(
    outputImage,
    from: outputImage.extent,
    format: .rgbXh,
    colorSpace: colorSpace
)
```

写入属性：

```swift
[
    kCGImageDestinationLossyCompressionQuality as String: quality,
    kCGImagePropertyHasAlpha as String: false,
    kCGImageDestinationEncodeRequest as String: outputPreset.isHDR
        ? kCGImageDestinationEncodeToISOHDR
        : kCGImageDestinationEncodeToSDR,
]
```

关键点：

- 使用 `.rgbXh`，避免 Apple 额外写 alpha/auxiliary 图像项。
- `kCGImagePropertyHasAlpha = false`，明确输出 opaque AVIF。
- HDR 时使用 `kCGImageDestinationEncodeToISOHDR`。
- SDR 时使用 `kCGImageDestinationEncodeToSDR`。

## 色彩预设

当前有效导出预设：

- `SDR sRGB`
- `Display P3 SDR`
- `Rec.2020 HLG HDR`
- `Rec.2020 PQ HDR`

HDR 预设对应的 `CGColorSpace`：

```swift
case .rec2020HLGHDR:
    CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
case .rec2020PQHDR:
    CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
```

旧的 `Display P3 HLG HDR` 已移除。HDR AVIF 统一走 BT.2020 / BT.2100 路径。

## 为什么只修元数据，不重写图像数据

当前 ImageIO 输出的 AVIF 已经满足这些条件：

```text
ColorPrimaries          : BT.2020
TransferCharacteristics : PQ 或 HLG
ImagePixelDepth         : 10 10 10
pix_fmt                 : yuv420p10le
```

也就是说，HDR 传递函数、BT.2020 色域和 10-bit 像素深度都已经存在。问题是 matrix 字段声明为 BT.709，导致解码器按不合适的 YCbCr matrix 解释这份 HDR AVIF。

修复的含义是：

```text
9 / 16或18 / 1  ->  9 / 16或18 / 9
```

这不是重新调色，也不是重新编码 AV1。它只修正“这份 AVIF 应该如何被解码器解释”的色彩信令。

如果像素数据本身确实是按 BT.709 matrix 生成的，只改信令会导致颜色偏差。但当前导出路径使用 BT.2100 HLG/PQ 色彩空间，且输出元数据已声明 BT.2020 primaries 和 PQ/HLG transfer，因此这里的修复是让 matrix 与实际 HDR 输出路径一致。

## 为什么需要修两层

AVIF 中至少有两处会携带色彩信令：

1. 容器层 `colr/nclx`
2. AV1 bitstream 的 sequence header

只修 `colr/nclx` 不够。验证时出现过这种情况：

```text
exiftool:
MatrixCoefficients : BT.2020 non-constant luminance

ffprobe:
color_space=bt709
```

这说明容器层已经正确，但 AV1 bitstream 内部仍然是 BT.709。Chrome/libavif 可能读取 bitstream 层，因此必须两层一起修。

最终正确状态应该是：

```text
exiftool:
MatrixCoefficients : BT.2020 non-constant luminance

ffprobe:
color_space=bt2020nc
```

## 后处理流程

AVIF 完成 `CGImageDestinationFinalize` 后，如果当前输出预设是 HDR，则调用：

```swift
try normalizeHDRAVIFColorMetadata(at: url)
```

流程：

1. 读取 AVIF 文件为 `Data`。
2. 遍历 BMFF box。
3. 在 `meta/iprp/ipco` 下查找 `colr` box。
4. 如果 `colr` 内容是 `nclx`，并且满足：

```text
colorPrimaries == 9
transferCharacteristics == 16 或 18
matrixCoefficients == 1
```

则把 matrix 改为 `9`。

5. 查找 `mdat` box。
6. 遍历 `mdat` 内的 AV1 OBU。
7. 找到 sequence header OBU。
8. 在 sequence header payload 中查找同样的色彩字段：

```text
9 / 16或18 / 1
```

9. 只把 matrix 的 8 bit 从 `1` 改成 `9`。
10. 如果至少修过一处字段，则原子写回文件。

后处理是有条件的：

- 只对 HDR AVIF 运行。
- 只修 BT.2020 + PQ/HLG + BT.709 matrix 的组合。
- SDR AVIF 不会被修改。
- 已经正确的 `matrix=9` 不会被修改。
- 其他未知组合不会被修改。

## 尺寸调整是否会影响 HDR

尺寸调整本身不会让 HDR 失效。

当前流程是先在 Core Image 中调整尺寸，再进入导出：

```text
CIImage 调整尺寸
  ↓
prepareImageForExport
  ↓
按输出预设选择 BT.2100 HLG/PQ 色彩空间
  ↓
ImageIO 写 AVIF
  ↓
修正 AVIF HDR 色彩信令
```

HDR 是否有效主要取决于：

- 输出预设是否是 HDR。
- 导出时是否使用 BT.2100 HLG/PQ 色彩空间。
- AVIF 是否是 10-bit。
- `colr/nclx` 和 AV1 sequence header 是否都写成标准 HDR 组合。

只要这些条件成立，缩放到 2048 或其他尺寸不会让 HDR 自动失效。

## 外部工具边界

AVIF 导出不调用外部工具：

- 不调用 `ffmpeg`
- 不调用 `avifenc`
- 不调用其他外部 AVIF 编码器

`ImageExporter.swift` 中仍有 `Process()`，但它只用于 Ultra HDR JPEG 的 `ultrahdr_app`：

```text
Ultra HDR JPEG -> Homebrew libultrahdr / ultrahdr_app
AVIF           -> Apple ImageIO + Swift 后处理
```

`scripts/check-avif.fish` 可能使用 `ffprobe`，但它只是检查脚本，不参与应用导出。

## 验证方法

导出后运行：

```fish
./scripts/check-avif.fish /path/to/file.avif
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

如果出现下面结果，说明只修了容器层，bitstream 层仍然错误：

```text
exiftool:
MatrixCoefficients : BT.2020 non-constant luminance

ffprobe:
color_space=bt709
```

如果出现下面结果，说明 Chrome HDR 兼容风险仍然存在：

```text
MatrixCoefficients : BT.709
```

或：

```text
ffprobe:
color_space=bt709
```

## 设计取舍

这套方案的取舍是：

- 保留 Apple ImageIO 作为 AVIF 编码器。
- 不引入 ffmpeg 或 avifenc 作为应用运行时依赖。
- 不重编码 AV1，避免速度和质量损失。
- 对 Apple 当前输出中不标准的 HDR matrix 信令做最小范围修正。

如果未来 Apple ImageIO 直接输出标准 `matrix=9`，后处理会因为条件不匹配而不改文件。届时可以删除这段后处理代码。
