# Ultra HDR JPEG 导出流程

## 背景

RawKit 的 Ultra HDR JPEG 导出依赖 Homebrew `libultrahdr` 提供的 `ultrahdr_app`。当前导出目标是生成普通 JPEG 可回退显示、同时包含 HDR gain map 的 Ultra HDR JPEG。

Homebrew `libultrahdr` v1.4.0 的默认编译参数是：

```text
UHDR_WRITE_XMP=FALSE
UHDR_WRITE_ISO=TRUE
```

因此 `ultrahdr_app` 直接输出的文件通常只包含 ISO 21496-1 gain map metadata，不包含 Chrome/Android 路径常用的 `hdrgm` XMP。RawKit 需要在编码完成后补写 XMP，同时保留 ISO 21496-1 metadata。

## 导出路径

核心实现位于 `RawKit/Services/ImageExporter.swift`：

```swift
exportUltraHDRJPEG(
    exportReadyImage,
    to: url,
    targetHeadroom: targetHDRHeadroom,
    quality: quality,
    compression: ultraHDRGainMapCompression,
    context: context
)
```

流程：

1. 查找 `ultrahdr_app`。
2. 生成临时 HDR raw 和 SDR raw。
3. 调用 `ultrahdr_app` 编码 Ultra HDR JPEG。
4. 调用 `ensureUltraHDRJPEGHasXMPMetadata(at:)` 修正 ISO metadata、补写 `hdrgm` XMP。

## 编码输入

HDR 输入：

```swift
let opaqueImage = makeOpaqueImageForJPEG(normalizedImage)
let hdrImage = normalizedHDRImage(opaqueImage, targetHeadroom: targetHeadroom)
```

输出为 RGBA half float raw：

```swift
renderHDRRawImage(... format: .RGBAh, colorSpace: extendedLinearITUR_2020)
```

SDR base 输入：

```swift
let sdrImage = makeOpaqueImageForJPEG(makeSDRBaseImage(from: hdrImage))
```

输出为 RGBA 8-bit raw：

```swift
renderSDRRawImage(... format: .RGBA8, colorSpace: sRGB)
```

## ultrahdr_app 参数

当前使用 encode scenario 1，同时传入 HDR intent 和 SDR intent：

```text
-m 0
-p hdr-rgba16f.raw
-y sdr-rgba8.raw
-a 4
-b 3
-C 2
-c 0
-t 0
-R 1
-q <base quality>
-Q <gain map quality>
-s <gain map scale factor>
-M 0
-D 1
-k 1.0
-K <max content boost>
-L <target peak nits>
-z <output jpg>
```

关键含义：

- `-a 4`：HDR raw 是 RGBA half float。
- `-b 3`：SDR raw 是 RGBA8888。
- `-C 2`：HDR intent 色域是 BT.2100。
- `-c 0`：SDR intent 色域是 BT.709。
- `-t 0`：HDR intent transfer 是 linear。
- `-R 1`：HDR intent 是 full range。
- `-M 0`：使用单通道 gain map，优先保证 Chrome/Android 兼容性。
- `-D 1`：编码 preset 是 best quality。

## 元数据后处理

`ultrahdr_app` 完成后，RawKit 会先修正第二张 gain map JPEG 里的 ISO 21496-1 metadata。即使文件已经包含 `http://ns.adobe.com/hdr-gain-map/1.0/`，也仍然会修正 ISO metadata 和 MPF 目录。

如果没有 `hdrgm` XMP，RawKit 还会补写 primary/gain map 两处 XMP：

1. 读取 JPEG 文件为 `Data`。
2. 定位 MPF 双图像结构。
3. 定位第一张 primary JPEG 和第二张 gain map JPEG。
4. 从第二张 JPEG 的 APP2 ISO 21496-1 block 读取 gain map metadata。
5. 解出 `GainMapMin`、`GainMapMax`、`Gamma`、`OffsetSDR`、`OffsetHDR`、`HDRCapacityMin`、`HDRCapacityMax`。
6. 归一化 ISO metadata 中的 `GainMapMin`、`HDRCapacityMin` 和 `HDRCapacityMax`。
7. 给 primary JPEG 插入 container XMP，声明 primary 和 gain map 两个 item。
8. 给 gain map JPEG 插入 `hdrgm` XMP。
9. 修正 MPF 中 primary/gain map 的长度和偏移。
10. 原子写回文件。

后处理不会重编码 JPEG 图像数据，只修改 APP marker 和 MPF 目录。

注意：MPF 目录里的第二图像起点不是文件绝对偏移，而是相对 MPF TIFF header 的偏移。检查时要确认 ExifTool 显示的 `MPImage2Start` 和真实第二个 JPEG SOI 位置一致，否则 Chrome 可能无法按目录找到 gain map。

Ultra HDR v1 需要按 Chrome/Android 路径更严格地归一化。由于 Chrome/Skia 在 ISO 和 XMP 同时存在时优先读取 ISO，ISO metadata 和 XMP 必须保持一致：

- `GainMapMin <= 0`。
- `GainMapMax >= GainMapMin`。
- `HDRCapacityMin >= 0`。
- `HDRCapacityMax > HDRCapacityMin`。
- `HDRCapacityMax` 尽量与 `GainMapMax` 对齐，避免普通 HDR 显示器上增益权重偏弱。
- gain map 子图尽量使用单通道。

后处理不会重编码 gain map JPEG 图像，只改 ISO metadata 的 rational 字段和新增 APP1 XMP。这样可以避免 `ultrahdr_app` 默认 `hdrCapacityMax` 明显大于 `maxContentBoost` 时，Chrome 按 ISO 元数据降低 gain map 权重。

## Skia 对照

Chrome 的 JPEG gain map 路径来自 Skia。对照 `skia/src/encode/SkJpegGainmapEncoder.cpp` 后，RawKit 需要关注这些行为：

- Skia 会同时写 ISO 21496-1 metadata 和 Ultra HDR v1 XMP。
- gain map XMP 里的 `GainMapMin`、`GainMapMax`、`HDRCapacityMin`、`HDRCapacityMax` 都是 log2 值。
- Skia 写 XMP 时 `HDRCapacityMax` 来自 display ratio 的 log2；Android 文档建议把它设置为 `GainMapMax`。
- Skia 的解码路径会优先使用 ISO metadata，XMP 主要作为兼容路径。
- Skia 会在 primary 和 gain map 两张 JPEG 中都写 MPF APP2 segment。RawKit 当前保留 `ultrahdr_app` 的 MPF 结构，只修正 primary MPF 目录；如果单通道和 ISO/XMP 归一化后 Chrome 仍不点亮，应继续对齐 Skia 的双 MPF segment 包装。

## 检查脚本

脚本位于：

```fish
fish scripts/check-ultrahdr-jpeg.fish /path/to/file.jpg
```

检查内容：

- JPEG 基础信息。
- ISO 21496-1 APP2 metadata。
- MPF 双图像结构。
- MPF 第二图像偏移是否匹配真实 JPEG SOI。
- 第二张 gain map JPEG。
- `hdrgm` XMP 字符串。
- gain map 子图是否是单通道。
- gain map 子图里的 `hdrgm` 数值是否适合 Chrome/Android Ultra HDR v1 路径。
- `ultrahdr_app` 是否能解码并导出 gain map metadata。
- ISO metadata 中 `hdrCapacityMax` 是否与 `maxContentBoost` 对齐。

样片检查：

```fish
fish scripts/check-ultrahdr-jpeg.fish DSC03344.jpg
```

## 预期状态

RawKit 新导出的 Ultra HDR JPEG 应满足：

```text
ISO 21496-1 metadata : 存在
MPF 双图像           : 存在
MPF 第二图像偏移      : 匹配真实 JPEG SOI
hdrgm XMP            : 存在
gain map 子图         : 单通道
ISO hdrCapacityMax   : 与 maxContentBoost 对齐
ultrahdr_app decode  : 成功
```

如果缺少 `hdrgm` XMP，Chrome/Android HDR 兼容风险较高。

如果缺少 ISO 21496-1 metadata，`ultrahdr_app` 或其他 ISO 路径解码器可能无法识别 gain map。

## 外部工具边界

Ultra HDR JPEG 导出使用外部工具：

```text
Ultra HDR JPEG -> Homebrew libultrahdr / ultrahdr_app + Swift JPEG 后处理
```
