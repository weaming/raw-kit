# LUT、HDR 与色彩空间变换处理流程

本文档说明 RawKit 当前图像处理管线中 **色彩空间管理、LUT 变换、HDR 增强与最终显示/导出** 的完整执行顺序与设计原则。

## 1. 工作色彩空间

- 渲染与直方图 `CIContext` 均使用线性工作空间 **`extendedLinearSRGB`**（见 `RawKit/Services/CIContextManager.swift`）。
- 在该空间中：
  - `> 1.0` 表示 HDR 高光亮度；
  - `< 0.0` 表示超出 sRGB 色域但合法的 Display P3 / Rec.2020 广色域颜色。
- 管线中所有自定义 Metal 滤镜、曲线与 LUT 混合均保留负值广色域与超白 HDR 数值，避免中途裁切。

## 2. 端到端处理流程图

```text
原图加载 (RAW / DNG / X3F / EXR / HDR GainMap / 普通图片)
  │  -> 解码进入 extendedLinearSRGB 线性工作空间
  ▼
1. 构图与裁切
  │  · 旋转 / 拉直 / 翻转 -> 裁切
  ▼
2. 基础、色彩与感知曲线调整
  │  · 曝光 / 感知曝光 / 对比度 / 高光阴影黑白 / 饱和度 / 自然饱和度 / 白平衡 / 清晰度 / 去雾
  │  · 曲线（RGB / R / G / B / Luminance）：1D 纹理在 sRGB 感知域查表，
  │    保留负值广色域与 > 1.0 HDR 高光线性延续，Luminance 曲线支持纯黑提亮
  ▼
3. LUT 色彩空间变换与 3D 查表（lutAlpha <= 0.001 时短路跳过）
  │  ├─ a. 色域转换：工作色域 (sRGB) --[3x3 矩阵 + Bradford 白点适应]--> inputGamut 线性 RGB
  │  ├─ b. HDR 高光压缩（仅 isHDREnabled == true 且输入传递函数为 SDR 有限域时启用）
  │  │     · 对 inputGamut 峰值 maxComponent 做 smoothstep 压缩，线性值 / scale
  │  │     · Log / HLG / PQ 原生支持 > 1.0 场景高光，不做压缩
  │  ├─ c. 编码 inputTransfer（sRGB / Gamma / Rec.709 / HLG / PQ / F-Log / F-Log2 / S-Log2 / S-Log3 / D-Log / C-Log3 / V-Log）
  │  ├─ d. 按 .cube 的 DOMAIN_MIN / DOMAIN_MAX 归一化到 [0, 1] -> CIColorCube 3D 查表
  │  │     （.3dl 文件解析时已转置为 R 轴最快，并按标准位深 10/12/16-bit 归一化）
  │  ├─ e. 解码 outputTransfer --[3x3 矩阵 + Bradford 白点适应]--> 工作色域 (sRGB) 线性 RGB
  │  ├─ f. 若步骤 b 启用了压缩，用原图转入 inputGamut 后的同一 scale 乘回高光
  │  └─ g. lerpImages(original, lutApplied, lutAlpha) 线性混合
  ▼
4. HDR 增强与 Headroom 保护（仅 isHDREnabled == true）
  │  · hdrBrightness / hdrHighlights / hdrWhites 任一非 0 时执行 hdrDisplayBoost
  │  · 按 RGB 峰值等比 Reinhard 肩部压缩（保持色相），硬上限钳位在 hdrHeadroom
  │  · 设置 contentHeadroom = hdrHeadroom（macOS 16+）
  ▼
5. 输出锐化 / 柔化（sharpness）
  │  · clampedToExtent -> 滤镜 -> cropped(to: originalExtent)，避免边缘透明光晕与尺寸膨胀
  ▼
6. 目标色彩空间渲染与输出
  ├─ 屏幕预览：HDR -> itur_2100_HLG / displayP3_HLG (.RGBAh)；SDR -> Display P3 (.RGBAh)
  ├─ TIFF / JPEG：sRGB / Display P3（.RGBA16 无损 / .RGBX8）
  ├─ HEIF / AVIF：sRGB / Display P3 / Rec.2020 + HLG / PQ（10-bit）
  └─ Ultra HDR JPEG：同色域线性 HDR (.RGBAh) + ToneMap SDR (.RGBA8) -> GainMap + ISO/XMP
```

## 3. 关键设计规则

### 3.1 LUT 与 HDR 的顺序
- **LUT 在 HDR 增强之前执行**：
  - 避免提亮型 LUT 冲破 `hdrHeadroom` 导致显示器硬裁切；
  - 避免 `Log / HLG / PQ -> Rec.709` 类 LUT 抵消前置的 HDR 增益；
  - 当开启 HDR 且叠加 SDR LUT 时，LUT 内部会先按 `inputGamut` 峰值压缩并等比还原，保留原片或前序调色产生的 `> 1.0` 高光。

### 3.2 跨白点色域转换
- `gamutTransformMatrix(from:to:)` 在源/目标白点不一致时（例如 `DCI-P3 (0.314, 0.351)` 与 `D65 (0.3127, 0.3290)`），自动应用 **Bradford 色适应矩阵**，确保中性灰不产生绿/品红偏色。

### 3.3 导出 `.cube` LUT
- `LUTGenerator` 与主渲染共用 `CIContextManager` 的线性 `extendedLinearSRGB` 工作空间；
- 生成 LUT 前自动剥离构图变换（旋转、拉直、翻转、裁切）与空间卷积滤镜（`clarity`、`sharpness`），仅保留点运算色彩调整，避免破坏 LUT 像素网格。

### 3.4 切换 LUT 时的参数同步
- 每个 LUT 的输入/输出色彩配置独立持久化在 `LUTPanel` 中，未配置过的新 LUT 默认使用 `.default`（sRGB -> sRGB）；
- 切换 LUT 时通过 `ImageEditingSession.applyLUT(_:profile:alpha:)` 原子提交 `lutURL`、`lutColorProfile` 与 `lutAlpha` 并同步回 `activeEditingState`。

## 4. 相关代码位置

| 模块 | 文件 |
| --- | --- |
| 工作色彩空间管理 | `RawKit/Services/CIContextManager.swift` |
| 主滤镜管线、LUT / HDR Metal Kernel 与色域矩阵 | `RawKit/Services/ImageProcessor.swift` |
| 感知曲线 1D Metal Kernel | `RawKit/Models/CurveAdjustment.swift` |
| 导出 `.cube` LUT | `RawKit/Services/LUTGenerator.swift` |
| LUT 面板与配置持久化 | `RawKit/Views/LUTPanel.swift` |
| Session 原子状态提交 | `RawKit/Models/ImageEditingSession.swift` |
| 多格式导出与 Ultra HDR 元数据修补 | `RawKit/Services/ImageExporter.swift`、`RawKit/Services/UltraHDRMetadataPatcher.swift` |
