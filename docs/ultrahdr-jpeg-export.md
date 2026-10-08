# Ultra HDR JPEG 导出流程

使用 libultrahdr 的 `ultrahdr_app` 编码 JPEG 基图和单通道增益图，再补写兼容 XMP。已用 Homebrew libultrahdr 2.0.2 验证。

## 色彩和亮度

- HDR 输入为预设色域的线性 RGBA half float。
- SDR 基图经过色调映射，使用同一色域、sRGB 传递函数的 RGBA8：P3 使用 Display P3，Rec.2020 使用 ITUR_2020_sRGBGamma。
- `-C` 和 `-c` 使用相同色域，确保 ISO 的增益应用色域与 XMP v1 的基底色域语义一致。
- libultrahdr 的线性参考白为 203 nits；`-L` 设置为 `min(max(headroom, 1.01) × 203, 10000)`。纯 SDR 内容也保留最小合法显示区间，避免编码器输出后被解码器以容量上下界相等拒绝。
- 不限制 `-k/-K`，让编码器从实际 HDR/SDR 像素计算增益范围，避免裁掉变暗区域或高光。
- 质量和缩放仍按高质量、均衡、小体积三档控制；增益图使用单通道。

## 元数据后处理

1. 编码到临时目录。
2. 解析两张 JPEG，从 ISO 21496-1 APP2 读取增益参数，保留 ISO 字节不变。
3. 移除已有 gain-map XMP，再写入主图 Container Directory 和增益图 hdrgm XMP。
4. 重新计算主图和增益图长度，以及相对 MPF TIFF header 的第二图起点。
5. 全部成功后原子写入目标文件；失败不覆盖已有文件。

后处理不改变 GainMapMin/Max、Gamma、Offset 或 HDRCapacity。修改这些参数而不重新编码增益图会改变还原结果。显示 headroom 与最大像素增益也不要求相等。

XMP 数值按百分号 `%g` 输出足够的有效位数（必要时带指数形式），保证与 ISO 有理数换算结果一致。不能无损表示为当前 XMP 路径的 ISO 数据（例如反向增益、非基底色域或不同通道的不同参数）会明确报错。当前编码参数产生 SDR 基底、同色域、单通道输出。

## 验证

`RawKitTests/UltraHDRExportTests.swift` 使用真实 `ultrahdr_app`：

- 覆盖四个 HDR 预设和三个压缩档位。
- 检查普通 JPEG 解码、MPF 偏移及 XMP 声明长度。
- 探测并解码为线性 half float，比较已知亮度阶梯和目标 headroom。
- 验证补写 XMP 前后 ISO 字节、HDR 解码像素不变。
- 禁用 ISO 识别后验证纯 XMP 路径还原相同像素，含非默认 gamma。
- 验证重复后处理不会重复插入 XMP，以及奇数尺寸、SDR headroom 和失败时文件保留。

手动检查：`fish scripts/check-ultrahdr-jpeg.fish /path/to/file.jpg`。

参考：[libultrahdr 增益图编码](https://github.com/google/libultrahdr/blob/main/lib/src/jpegr.cpp)、[ISO 元数据转换](https://github.com/google/libultrahdr/blob/main/lib/src/gainmapmetadata.cpp)。
