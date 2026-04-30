# RawKit

RawKit 是一个 macOS 本地 RAW 图像预览和处理工具，面向需要快速筛片、基础调色、曲线校正、LUT 预览和批量导出的工作流。

## 功能特性

### 图像格式支持
- RAW：ARW、X3F、CR2 / CR3、NEF、ORF、RAF、RW2、DNG 等
- 常规图像：JPEG、PNG、TIFF

### 浏览与取样
- 主视口支持滚轮缩放、拖拽平移、双击重置缩放
- 小图直接全分辨率加载；大图使用缩略图快速起显，再切换到高分辨率预览
- 实时直方图（RGB + 亮度）
- 底部状态栏实时显示当前主视口对应的颜色读数
  - 显示域 RGB / HSL / HEX
  - 线性 RGB 参考值
- 白平衡吸管支持放大镜浮窗与十字准星预览，`Esc` 可退出吸管模式
- 文件元数据与色彩空间信息显示

### 实时调整

**基础**
- 曝光（EV）
- 感知曝光
- 对比度
- 白色
- 高光
- 阴影
- 黑色

**色彩**
- 白平衡（2000K - 25000K，默认 D65 / 6500K）
- 自动白平衡（基于线性域中性色样本估计）
- 白平衡吸管取色
- 色调（Tint）
- 饱和度
- 自然饱和度
- RGB 主曲线
- 红 / 绿 / 蓝独立曲线
- 亮度曲线
- 黑 / 灰 / 白三点取样校色

**LUT**
- 支持 `.cube`、`.3dl`、`.lut`
- 支持导入单个 LUT 文件或整个文件夹，并递归扫描子目录
- 导入后的 LUT 按来源文件夹分组显示
- 分组展开 / 折叠状态会在重启后保留
- LUT 强度可调
- 支持分别设置 LUT 的输入色域、输入曲线、输出色域、输出曲线
- 支持将当前调整保存为 LUT

**细节**
- 清晰度
- 去雾
- 锐化

**变换**
- 90° 旋转
- 水平镜像
- 垂直镜像

### 工作流
- 撤销 / 重做（`⌘Z` / `⌘⇧Z`）
- 分组重置（基础 / 色彩 / 细节）
- 全局重置（保留变换与 LUT）
- 批量同步设置，可按 `LUT / 基础 / 色彩 / 细节` 选择同步范围
- 拖入文件或文件夹打开图片；已有图片时也可继续拖入追加
- 底部胶片栏支持多选，`⌘A` 可全选当前照片
- 自动提取 RAW 原始白平衡

### 导出
- TIFF 16-bit
- JPEG（可调质量）
- HEIF
- AVIF（libavif 10-bit）
- Ultra HDR JPEG
- DNG 16-bit
- 输出预设：SDR sRGB、Display P3 SDR、Display P3 HLG/PQ HDR、Rec.2020 HLG/PQ HDR
- 导出预设
- 可配置输出尺寸、命名前后缀、输出目录
- 批量导出当前图片列表

## 技术栈

- Swift 5
- SwiftUI（macOS 15.1+）
- Core Image
- CGImageSource / CIRAWFilter
- Actor 并发模型

## 构建和运行

1. 打开项目：
   ```bash
   open RawKit.xcodeproj
   ```
2. 在 Xcode 中选择 `My Mac`
3. 运行 `⌘R`

也可以直接命令行构建：

```bash
xcodebuild -project RawKit.xcodeproj -scheme RawKit -configuration Debug -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO
```

## 系统要求

- macOS 15.1+
- Xcode 16.2+
- 8GB 以上内存更适合大尺寸 RAW 处理

## 截屏

![](screenshots/p1.jpg)
