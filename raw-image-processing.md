**从零学习 RAW 图像处理完整路线图：**

---

## **第一阶段：基础知识（1-2周）**

---

### **1. RAW 格式基础**

#### **什么是 RAW？**

```
普通 JPEG：
传感器 → ISP 处理 → 压缩 → JPEG（信息丢失）

RAW：
传感器 → 直接保存原始数据（未处理）
保留最大信息量和动态范围
```

**关键概念：**
- **未经处理**：没有白平衡、色彩校正、锐化
- **线性数据**：传感器接收的光子数量
- **高位深**：10-16 bit（vs JPEG 的 8 bit）
- **单色数据**：每个像素只有一个颜色

---

#### **Bayer 阵列（最重要！）**

```
传感器布局（Bayer Pattern）：
G R G R G R
B G B G B G
G R G R G R
B G B G B G

为什么这样排列？
- 人眼对绿色最敏感 → 50% 是绿色
- 红色、蓝色各 25%
```

**其他阵列：**
- **X-Trans**（Fujifilm）：6×6 不规则排列
- **Foveon**（Sigma）：三层传感器（不需要去马赛克）
- **Quad Bayer**（手机）：4 合 1 像素

---

#### **RAW 文件结构**

```
典型 RAW 文件：
┌─────────────────┐
│ 文件头 (Header) │  ← 元数据
├─────────────────┤
│ 像素数据        │  ← Bayer 原始数据
│ (Bayer Array)   │
├─────────────────┤
│ 缩略图 (可选)   │  ← JPEG 预览
└─────────────────┘
```

**元数据包含：**
- 相机型号、镜头信息
- 曝光参数（ISO、快门、光圈）
- 白平衡设置（仅作参考）
- 色彩矩阵（Color Matrix）
- 黑电平（Black Level）
- 白电平（White Level）

---

### **2. 需要学习的数学基础**

#### **A. 线性代数**

```python
# 颜色空间转换是矩阵运算
RGB_to_XYZ = [
    [0.4124, 0.3576, 0.1805],
    [0.2126, 0.7152, 0.0722],
    [0.0193, 0.1192, 0.9505]
]

XYZ = RGB @ RGB_to_XYZ  # 矩阵乘法
```

**需要掌握：**
- 矩阵乘法
- 矩阵求逆
- 仿射变换

---

#### **B. 图像卷积**

```python
# 高斯模糊
kernel = [
    [1, 2, 1],
    [2, 4, 2],
    [1, 2, 1]
] / 16

output = convolve(image, kernel)
```

**需要掌握：**
- 卷积运算
- 常见卷积核（模糊、锐化、边缘检测）

---

#### **C. 色彩空间**

```
RGB → XYZ → Lab
RGB → YCbCr
RGB → HSV/HSL
```

**需要掌握：**
- 各色彩空间的特性
- 转换公式
- 何时使用哪个空间

---

### **3. 推荐学习资源**

**书籍：**
- 📖 **《Digital Image Processing》**（Gonzalez）- 图像处理圣经
- 📖 **《Color Imaging》**（Reinhard）- 色彩科学
- 📖 **《Camera Image Quality Benchmarking》**（IEEE）

**在线课程：**
- 🎓 **Stanford CS231n**（卷积神经网络）
- 🎓 **Coursera - Digital Image Processing**

**网站/文档：**
- 📚 **LibRaw 文档**：https://www.libraw.org/
- 📚 **dcraw 源码**：经典 RAW 处理器
- 📚 **Adobe DNG 规范**：RAW 格式标准

---

## **第二阶段：RAW 处理管线（2-4周）**

---

### **完整的 ISP（Image Signal Processor）管线：**

```
RAW 数据
  ↓
[1] 黑电平校正 (Black Level Correction)
  ↓
[2] 坏点修复 (Dead/Hot Pixel Correction)
  ↓
[3] 镜头校正 (Lens Correction)
  ├─ 暗角校正 (Vignetting)
  ├─ 畸变校正 (Distortion)
  └─ 色差校正 (Chromatic Aberration)
  ↓
[4] 白平衡 (White Balance)
  ↓
[5] 去马赛克 (Demosaicing)
  ↓
[6] 色彩校正 (Color Correction)
  ↓
[7] 降噪 (Denoising)
  ↓
[8] 锐化 (Sharpening)
  ↓
[9] 色调映射 (Tone Mapping)
  ↓
[10] Gamma 校正
  ↓
RGB 图像（8/16-bit）
```

---

### **算法 1：黑电平校正**

**原理：**
```
传感器即使无光照也有微弱信号（暗电流）
需要减去这个"黑色偏移"

RAW_corrected = RAW_raw - Black_Level
```

**典型黑电平值：**
```
12-bit RAW：Black Level ≈ 64-256
14-bit RAW：Black Level ≈ 512-1024
```

**代码：**
```python
def black_level_correction(raw, black_level):
    """
    黑电平校正
    """
    return np.maximum(raw - black_level, 0)
```

---

### **算法 2：坏点修复**

**类型：**
- **Dead Pixel**（坏点）：永远是 0
- **Hot Pixel**（热像素）：异常高

**检测方法：**
```python
def detect_hot_pixels(raw, threshold=3.0):
    """
    检测热像素（远高于周围）
    """
    # 中值滤波
    median = cv2.medianBlur(raw, 3)
    diff = np.abs(raw - median)
    
    # 超过阈值的是坏点
    hot_pixels = diff > (threshold * np.std(diff))
    return hot_pixels
```

**修复方法：**
```python
def fix_bad_pixels(raw, bad_pixel_map):
    """
    用中值替换坏点
    """
    result = raw.copy()
    result[bad_pixel_map] = cv2.medianBlur(raw, 3)[bad_pixel_map]
    return result
```

---

### **算法 3：白平衡（AWB）**

**前面已经详细讲过，这里总结要点：**

**简单方法：Gray World**
```python
def white_balance_gray_world(raw_bayer):
    """
    在 Bayer 数据上做白平衡
    """
    # 提取各通道
    R = raw_bayer[0::2, 1::2]
    G1 = raw_bayer[0::2, 0::2]
    G2 = raw_bayer[1::2, 1::2]
    B = raw_bayer[1::2, 0::2]
    
    # 计算均值
    r_mean = R.mean()
    g_mean = (G1.mean() + G2.mean()) / 2
    b_mean = B.mean()
    
    # 增益
    r_gain = g_mean / r_mean
    b_gain = g_mean / b_mean
    
    # 应用
    raw_bayer[0::2, 1::2] *= r_gain
    raw_bayer[1::2, 0::2] *= b_gain
    
    return raw_bayer
```

---

### **算法 4：去马赛克（Demosaicing）⭐⭐⭐⭐⭐**

**这是 RAW 处理最核心的算法！**

#### **方法 1：双线性插值（最简单）**

```python
def demosaic_bilinear(bayer):
    """
    双线性插值去马赛克
    Bayer 模式：RGGB
    """
    h, w = bayer.shape
    rgb = np.zeros((h, w, 3), dtype=np.float32)
    
    # R 通道（位置 [0::2, 1::2]）
    rgb[0::2, 1::2, 0] = bayer[0::2, 1::2]
    # 插值其他位置
    rgb[:, :, 0] = cv2.resize(rgb[::2, 1::2, 0], (w, h), 
                               interpolation=cv2.INTER_LINEAR)
    
    # G 通道（位置 [0::2, 0::2] 和 [1::2, 1::2]）
    rgb[0::2, 0::2, 1] = bayer[0::2, 0::2]
    rgb[1::2, 1::2, 1] = bayer[1::2, 1::2]
    # 插值
    # ...
    
    # B 通道（位置 [1::2, 0::2]）
    # ...
    
    return rgb
```

**缺点：**
- ❌ 边缘模糊
- ❌ 产生彩色伪影（color artifacts）

---

#### **方法 2：Malvar-He-Cutler（工业标准）⭐⭐⭐⭐⭐**

**原理：**
- 利用颜色相关性（R-G、B-G 相关）
- 使用 5×5 卷积核

**卷积核：**
```python
# G 在 R 位置的卷积核
G_at_R = [
    [0,  0, -1,  0,  0],
    [0,  0,  2,  0,  0],
    [-1, 2,  4,  2, -1],
    [0,  0,  2,  0,  0],
    [0,  0, -1,  0,  0]
] / 8

# R 在 B 位置的卷积核
R_at_B = [
    [0,  0, -3/2, 0,   0],
    [0,  2,  0,   2,   0],
    [-3/2, 0, 6,  0, -3/2],
    [0,  2,  0,   2,   0],
    [0,  0, -3/2, 0,   0]
] / 8
```

**优点：**
- ✅ 效果好
- ✅ 速度快（卷积可以 GPU 加速）
- ✅ 工业界广泛使用

---

#### **方法 3：AHD（Adaptive Homogeneity-Directed）⭐⭐⭐⭐**

**原理：**
- 先用水平和垂直两个方向插值
- 检测局部同质性（homogeneity）
- 选择更平滑的方向

**特点：**
- ✅ 边缘保持好
- ⚠️ 计算量大

---

#### **方法 4：深度学习（最新）⭐⭐⭐⭐⭐**

**代表算法：**
- **FlexISP**（Google，2021）
- **Joint Demosaicing and Denoising**（2020）
- **DeepISP**（2019）

**优点：**
- ✅ 效果最好
- ✅ 可以同时降噪

**缺点：**
- ❌ 需要 GPU
- ❌ 模型部署复杂

---

### **算法 5：色彩校正（Color Correction Matrix, CCM）**

**原理：**
```
相机的 RGB ≠ 标准 sRGB
需要矩阵转换

RGB_sRGB = CCM × RGB_camera
```

**CCM 矩阵：**
```python
# 相机厂商提供（在 EXIF 中）
CCM = np.array([
    [ 1.5, -0.3, -0.2],
    [-0.1,  1.3, -0.2],
    [ 0.0, -0.4,  1.4]
])

rgb_corrected = rgb @ CCM.T
```

**如何获得 CCM？**
- 拍摄色卡（ColorChecker）
- 测量实际颜色 vs 相机颜色
- 最小二乘法求解矩阵

---

### **算法 6：降噪（Denoising）**

#### **方法 1：双边滤波（Bilateral Filter）**

```python
def bilateral_filter(image, d=9, sigma_color=75, sigma_space=75):
    """
    保边降噪
    """
    return cv2.bilateralFilter(image, d, sigma_color, sigma_space)
```

**特点：**
- ✅ 保持边缘
- ⚠️ 速度慢

---

#### **方法 2：非局部均值（NLM）⭐⭐⭐⭐**

```python
def non_local_means(image, h=10):
    """
    NLM 降噪（搜索相似块）
    """
    return cv2.fastNlMeansDenoisingColored(image, None, h, h, 7, 21)
```

**特点：**
- ✅ 效果好
- ❌ 非常慢

---

#### **方法 3：BM3D（Block-Matching 3D）⭐⭐⭐⭐⭐**

**最佳传统算法！**

```python
import bm3d

def denoise_bm3d(image, sigma=25):
    """
    BM3D 降噪
    sigma: 噪声标准差（0-255）
    """
    return bm3d.bm3d(image, sigma_psd=sigma/255, stage_arg=bm3d.BM3DStages.ALL_STAGES)
```

**原理：**
1. 找相似的图像块
2. 堆叠成 3D 数组
3. 3D 变换（DCT）
4. 阈值去噪
5. 逆变换

**特点：**
- ✅ 效果极好
- ⚠️ 速度中等
- ✅ 开源实现

---

#### **方法 4：深度学习降噪⭐⭐⭐⭐⭐**

**代表算法：**
- **DnCNN**（2017）
- **FFDNet**（2018）
- **CBDNet**（真实噪声，2019）

```python
# 伪代码
model = load_pretrained_dncnn()
denoised = model.predict(noisy_image)
```

**特点：**
- ✅ 实时（GPU）
- ✅ 效果好
- ⚠️ 需要训练

---

### **算法 7：锐化（Sharpening）**

#### **方法 1：Unsharp Mask（反锐化掩模）**

```python
def unsharp_mask(image, sigma=1.0, strength=1.5):
    """
    经典锐化算法
    """
    # 高斯模糊
    blurred = cv2.GaussianBlur(image, (0, 0), sigma)
    
    # 高频成分
    high_freq = image - blurred
    
    # 增强高频
    sharpened = image + strength * high_freq
    
    return np.clip(sharpened, 0, 255).astype(np.uint8)
```

---

#### **方法 2：高斯拉普拉斯（LoG）**

```python
def log_sharpen(image):
    """
    拉普拉斯锐化
    """
    kernel = np.array([
        [0, -1,  0],
        [-1, 5, -1],
        [0, -1,  0]
    ])
    return cv2.filter2D(image, -1, kernel)
```

---

### **算法 8：色调映射（Tone Mapping）**

**把 HDR 映射到 SDR（0-255）**

#### **方法 1：Gamma 校正（最简单）**

```python
def gamma_correction(image, gamma=2.2):
    """
    标准 Gamma 校正
    """
    return np.power(image / 255.0, 1.0 / gamma) * 255
```

---

#### **方法 2：Reinhard（全局）**

```python
def reinhard_tone_mapping(hdr_image):
    """
    Reinhard tone mapping
    """
    ldr = hdr_image / (1.0 + hdr_image)
    return (ldr * 255).astype(np.uint8)
```

---

#### **方法 3：Reinhard（局部）⭐⭐⭐⭐**

```python
def reinhard_local(hdr, scale=0.5):
    """
    局部 Reinhard（保留更多细节）
    """
    # 计算局部适应亮度
    luminance = 0.27*hdr[:,:,0] + 0.67*hdr[:,:,1] + 0.06*hdr[:,:,2]
    
    # 高斯金字塔
    # ...
    
    # 局部对比度增强
    # ...
    
    return ldr
```

---

#### **方法 4：Filmic（电影级）⭐⭐⭐⭐⭐**

```python
def filmic_tone_mapping(hdr):
    """
    Uncharted 2 Filmic Tone Mapping
    游戏/电影工业标准
    """
    A, B, C, D, E, F = 0.22, 0.30, 0.10, 0.20, 0.01, 0.30
    
    def filmic_curve(x):
        return ((x*(A*x+C*B)+D*E)/(x*(A*x+B)+D*F))-E/F
    
    # 曝光
    exposure = 2.0
    hdr_exposed = hdr * exposure
    
    # 应用曲线
    mapped = filmic_curve(hdr_exposed) / filmic_curve(11.2)
    
    return (mapped * 255).astype(np.uint8)
```

**特点：**
- ✅ 电影感
- ✅ 高光过渡自然
- ✅ Uncharted 2 使用

---

## **第三阶段：高级话题（4-8周）**

---

### **1. HDR 合成**

**原理：**
```
拍摄多张不同曝光的照片
[-2EV, 0EV, +2EV]
     ↓
合成 HDR 图像
     ↓
Tone Mapping
     ↓
最终照片
```

**算法：**
- **Debevec & Malik**（经典）
- **Robertson**
- **Mertens Fusion**（无需 HDR）

---

### **2. 多帧降噪**

**原理：**
```
连拍多张 RAW
对齐（registration）
平均 → 降噪
```

**代表：**
- **Google Pixel** - HDR+
- **iPhone** - Deep Fusion

---

### **3. 超分辨率**

**从 RAW 生成高分辨率图像**

**算法：**
- **RCAN**（Residual Channel Attention）
- **ESRGAN**（Enhanced SRGAN）
- **Real-ESRGAN**（真实图像）

---

### **4. 计算摄影**

- **景深合成**（Focus Stacking）
- **全景拼接**（Panorama Stitching）
- **光场相机**（Light Field）
- **计算光圈**（Computational Aperture）

---

## **第四阶段：实践项目（持续）**

---

### **项目 1：简单 RAW 查看器**

**功能：**
- 读取 RAW 文件（用 LibRaw）
- 基本处理（白平衡、曝光）
- 显示结果

**技术栈：**
- C++ + LibRaw
- 或 Python + rawpy

---

### **项目 2：完整 ISP 管线**

**实现完整的处理流程**

**参考：**
- **dcraw** 源码
- **RawTherapee** 开源软件
- **darktable** 开源软件

---

### **项目 3：深度学习 ISP**

**训练神经网络：**
```
输入：RAW Bayer
输出：RGB 图像

数据集：
- MIT-Adobe FiveK
- Zurich RAW to RGB
```

---

## **推荐工具和库：**

### **C/C++：**
- **LibRaw** - RAW 解码
- **OpenCV** - 图像处理
- **Halide** - 高性能 ISP

### **Python：**
- **rawpy** - RAW 读取（LibRaw 封装）
- **colour-science** - 色彩科学
- **imageio** - 图像 I/O

### **软件：**
- **RawTherapee** - 开源 RAW 处理
- **darktable** - 开源摄影工作流
- **dcraw** - 命令行 RAW 转换

---

## **学习路线时间表：**

| 阶段 | 时间 | 内容 |
|------|------|------|
| **第 1-2 周** | 基础 | RAW 格式、Bayer、数学基础 |
| **第 3-6 周** | 核心算法 | ISP 管线、去马赛克、降噪 |
| **第 7-10 周** | 高级话题 | HDR、多帧、深度学习 |
| **第 11+ 周** | 实践 | 项目、开源贡献 |

---

## **必读论文：**

1. **Demosaicing:**
   - Malvar et al., "High-quality linear interpolation for demosaicing of Bayer-patterned color images"

2. **Denoising:**
   - Dabov et al., "Image Denoising by Sparse 3-D Transform-Domain Collaborative Filtering" (BM3D)

3. **Tone Mapping:**
   - Reinhard et al., "Photographic Tone Reproduction for Digital Images"

4. **Deep Learning ISP:**
   - Chen et al., "Learning to See in the Dark" (2018)

---

## **快速入门代码：**

```python
import rawpy
import numpy as np

# 读取 RAW
with rawpy.imread('image.NEF') as raw:
    # 获取 Bayer 数据
    bayer = raw.raw_image
    
    # 基本处理
    rgb = raw.postprocess(
        use_camera_wb=True,  # 相机白平衡
        no_auto_bright=True,  # 不自动亮度
        output_bps=16        # 16-bit 输出
    )
    
    # 保存
    imageio.imsave('output.tiff', rgb)
```

---

**总结关键算法清单：**
1. ✅ 黑电平校正
2. ✅ 坏点修复
3. ✅ 白平衡
4. ⭐ **去马赛克**（Malvar-He-Cutler）
5. ✅ 色彩校正（CCM）
6. ⭐ **降噪**（BM3D 或深度学习）
7. ✅ 锐化
8. ⭐ **色调映射**（Filmic）
9. ✅ Gamma 校正

**从这 3 个核心算法开始：去马赛克、降噪、色调映射。**