# 功能列表

## 图像格式

- RAW：ARW、X3F、CR2、CR3、NEF、ORF、RAF、RW2、DNG 等
- 常规图像：JPEG、PNG、TIFF、HEIF、AVIF
- X3F 可调用内置 `x3f-extract` 生成预览和线性 DNG 中间结果

## 浏览与取样

- 主视口支持滚轮缩放、拖拽平移、双击重置缩放
- 小图直接全分辨率加载；大图先快速起显，再切换到高分辨率预览
- 实时直方图，支持 SDR 和 HDR 范围显示
- 底部状态栏显示当前视口取样颜色
- 显示域 RGB、HSL、HEX 和线性 RGB 参考值
- 白平衡吸管支持放大镜浮窗与十字准星预览
- 文件元数据与色彩空间信息显示

## 实时调整

### 基础

- 曝光
- 感知曝光
- 对比度
- 白色
- 高光
- 阴影
- 黑色

### 色彩

- 白平衡
- 自动白平衡
- 白平衡吸管取色
- 色调
- 饱和度
- 自然饱和度
- RGB 主曲线
- 红、绿、蓝独立曲线
- 亮度曲线
- 黑、灰、白三点取样校色

### LUT

- 支持 `.cube`、`.3dl`、`.lut`
- 支持导入单个 LUT 文件或整个文件夹，并递归扫描子目录
- 导入后的 LUT 按来源文件夹分组显示
- 分组展开状态会在重启后保留
- LUT 强度可调
- LUT 可配置输入色域、输入曲线、输出色域、输出曲线
- HDR 开启时使用高光保护查表，减少高光被夹到 SDR 范围
- 支持将当前调整保存为 LUT

### 细节

- 清晰度
- 去雾
- 锐化

### 构图

- 90 度旋转
- 任意角度拉直
- 水平镜像
- 垂直镜像
- 比例裁剪
- 四边裁剪

## HDR 与色彩导出

- 输出预设：
  - SDR sRGB
  - Display P3 SDR
  - Display P3 HLG HDR
  - Display P3 PQ HDR
  - Rec.2020 HLG HDR
  - Rec.2020 PQ HDR
- HEIF HDR 会修正 `nclx` 和 HEVC SPS/VUI 色彩信令
- HEIF 后处理会移除多余 `ImageDescription`
- X3F 输入导出 HEIF 时使用 10-bit 4:4:4
- AVIF 使用 `avifenc` 写入 10-bit 输出和 CICP 色彩信令
- Ultra HDR JPEG 使用 gain map，并补齐兼容 Chrome/Android 的 XMP/ISO 元数据

## 导出格式

- TIFF 16-bit
- JPEG
- HEIF
- AVIF
- Ultra HDR JPEG
- DNG 16-bit
- 可配置质量、尺寸、命名前后缀和输出目录
- 支持导出预设
- 支持批量导出当前图片列表

## 工作流

- 撤销 / 重做
- 分组重置
- 全局重置
- 批量同步设置
- 拖入文件或文件夹打开图片
- 已有图片时可继续拖入追加
- 底部胶片栏支持多选
- 自动提取 RAW 原始白平衡

## 检查脚本

- `scripts/check-heif.fish`：检查 HEIF 容器、nclx、HEVC bitstream、CLLI、ICC/XMP 和多余结构
- `scripts/check-avif.fish`：检查 AVIF 容器与 AV1 bitstream 色彩信令
- `scripts/check-ultrahdr-jpeg.fish`：检查 Ultra HDR JPEG gain map、XMP、ISO 21496-1 和 MPF
- `scripts/compare-exif.py`：对比两张图的 ExifTool 元信息，并补充 HEVC bitstream 判断
