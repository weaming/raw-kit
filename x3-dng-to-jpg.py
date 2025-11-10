#!/usr/bin/env python3
"""
DNG to sRGB JPEG Converter
支持普通 Bayer 和 Foveon X3F DNG

brew install exiftool
exiftool -a -G1 DP3Q0109.X3F.dng | grep -iE "white|balance|neutral|illuminant|color|temp|tint|shutter|aperture|speed"

pip install rawpy imageio numpy scipy exifread
"""

import argparse
from pathlib import Path

import imageio
import numpy as np
import rawpy


def load_dng_metadata(raw):
    """
    提取 DNG 元数据
    """
    metadata = {
        'camera_wb': raw.camera_whitebalance,
        'daylight_wb': raw.daylight_whitebalance,
        'black_level': raw.black_level_per_channel,
        'white_level': raw.white_level,
        'color_desc': raw.color_desc.decode('utf-8'),
        'num_colors': raw.num_colors,
        'raw_pattern': (
            raw.raw_pattern.tolist() if hasattr(raw, 'raw_pattern') and raw.raw_pattern is not None else None
        ),
    }

    # 计算白平衡增益
    wb = metadata['camera_wb']
    if len(wb) >= 3:
        r_gain = 1.0 / wb[0]
        g_gain = 1.0 / wb[1]
        b_gain = 1.0 / wb[2]

        # 归一化（G 为 1.0）
        metadata['wb_gains'] = [r_gain / g_gain, 1.0, b_gain / g_gain]

    return metadata


def iterative_white_balance(image, initial_wb=None, max_iter=3, damping=0.5):
    """
    迭代白平衡优化

    Args:
        image: RGB 浮点图像 [0, 1]
        initial_wb: 初始白平衡 [r_gain, g_gain, b_gain]
        max_iter: 最大迭代次数
        damping: 阻尼系数（0-1）

    Returns:
        校正后的图像
    """
    result = image.copy()

    if initial_wb is None:
        gains = np.array([1.0, 1.0, 1.0])
    else:
        gains = np.array(initial_wb)

    for iteration in range(max_iter):
        # 应用当前增益
        result[:, :, 0] = image[:, :, 0] * gains[0]
        result[:, :, 1] = image[:, :, 1] * gains[1]
        result[:, :, 2] = image[:, :, 2] * gains[2]

        # 去除异常值后计算均值
        brightness = result.mean(axis=2)
        lower = np.percentile(brightness, 5)
        upper = np.percentile(brightness, 95)
        mask = (brightness > lower) & (brightness < upper)

        if not mask.any():
            break

        r_mean = result[:, :, 0][mask].mean()
        g_mean = result[:, :, 1][mask].mean()
        b_mean = result[:, :, 2][mask].mean()

        gray = (r_mean + g_mean + b_mean) / 3

        # 计算新增益（带阻尼）
        r_correction = 1.0 + damping * (gray / r_mean - 1.0)
        g_correction = 1.0 + damping * (gray / g_mean - 1.0)
        b_correction = 1.0 + damping * (gray / b_mean - 1.0)

        gains[0] *= r_correction
        gains[1] *= g_correction
        gains[2] *= b_correction

        # 检查收敛
        delta = max(abs(r_correction - 1.0), abs(g_correction - 1.0), abs(b_correction - 1.0))

        if delta < 0.01:
            print(f"  白平衡收敛于第 {iteration + 1} 次迭代")
            break

    # 裁剪到有效范围
    result = np.clip(result, 0, 1)

    return result


def apply_tone_mapping(image, method='filmic', exposure=1.0):
    """
    色调映射（HDR → SDR）

    Args:
        image: 线性 RGB [0, inf]
        method: 'gamma' | 'reinhard' | 'filmic'
        exposure: 曝光补偿
    """
    # 曝光调整
    img = image * exposure

    if method == 'gamma':
        # 简单 Gamma 2.2
        return np.power(np.clip(img, 0, 1), 1.0 / 2.2)

    elif method == 'reinhard':
        # Reinhard tone mapping
        return img / (1.0 + img)

    elif method == 'filmic':
        # Uncharted 2 Filmic Tone Mapping
        def filmic_curve(x):
            A, B, C, D, E, F = 0.22, 0.30, 0.10, 0.20, 0.01, 0.30
            return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F

        white_point = 11.2
        mapped = filmic_curve(img) / filmic_curve(white_point)

        return mapped

    else:
        raise ValueError(f"Unknown tone mapping method: {method}")


def calculate_auto_exposure(raw, dng_path, target_brightness=0.18):
    """
    根据 EXIF 和图像直方图自动计算曝光补偿

    Args:
        raw: rawpy 对象
        target_brightness: 目标中间调亮度 (0.18 = 18% 灰)

    Returns:
        exposure_compensation: 曝光补偿系数
    """
    import exifread

    # 1. 从 EXIF 读取曝光参数
    try:
        # 获取 EXIF 数据
        with open(dng_path, 'rb') as f:
            tags = exifread.process_file(f, details=False)

        # ISO
        iso = None
        if 'EXIF ISOSpeedRatings' in tags:
            iso = float(str(tags['EXIF ISOSpeedRatings']))
        elif 'Image ISO Speed Ratings' in tags:
            iso = float(str(tags['Image ISO Speed Ratings']))

        # 曝光时间
        exp_time = None
        if 'EXIF ExposureTime' in tags:
            exp_str = str(tags['EXIF ExposureTime'])
            if '/' in exp_str:
                num, denom = exp_str.split('/')
                exp_time = float(num) / float(denom)
            else:
                exp_time = float(exp_str)

        # 光圈
        aperture = None
        if 'EXIF FNumber' in tags:
            ap_str = str(tags['EXIF FNumber'])
            if '/' in ap_str:
                num, denom = ap_str.split('/')
                aperture = float(num) / float(denom)
            else:
                aperture = float(ap_str)

        # 曝光补偿（相机设置）
        ev_compensation = 0.0
        if 'EXIF ExposureBiasValue' in tags:
            ev_str = str(tags['EXIF ExposureBiasValue'])
            if '/' in ev_str:
                num, denom = ev_str.split('/')
                ev_compensation = float(num) / float(denom)
            else:
                ev_compensation = float(ev_str)

        print(f"  EXIF 曝光参数:")
        print(f"    ISO: {iso}")
        print(f"    快门: {exp_time}s" if exp_time else "    快门: 未知")
        print(f"    光圈: f/{aperture}" if aperture else "    光圈: 未知")
        print(f"    曝光补偿: {ev_compensation:+.1f} EV")

    except Exception as e:
        print(f"  无法读取 EXIF: {e}")
        iso = None
        exp_time = None
        aperture = None
        ev_compensation = 0.0

    # 2. 计算基础曝光系数（基于 ISO）
    base_exposure = 1.0

    if iso is not None:
        # ISO 100 为基准
        # ISO 越高，传感器越敏感，需要降低增益
        base_exposure = 100.0 / iso
        print(f"  基于 ISO 的曝光系数: {base_exposure:.3f}")

    # 3. 应用相机的曝光补偿
    if ev_compensation != 0:
        ev_multiplier = 2**ev_compensation
        base_exposure *= ev_multiplier
        print(f"  应用 EV 补偿后: {base_exposure:.3f}")

    # 4. 分析图像直方图
    # 快速处理一个小图来分析亮度
    params = rawpy.Params(
        use_camera_wb=True,
        output_bps=16,
        gamma=(1, 1),  # 线性
        no_auto_bright=True,
    )

    # 获取缩略图用于快速分析
    thumb = raw.postprocess(params)
    thumb_float = thumb.astype(np.float32) / 65535.0

    # 计算亮度（使用 Rec. 709 系数）
    luminance = 0.2126 * thumb_float[:, :, 0] + 0.7152 * thumb_float[:, :, 1] + 0.0722 * thumb_float[:, :, 2]

    # 去除过亮和过暗区域（前后 5%）
    sorted_lum = np.sort(luminance.flatten())
    lower_idx = int(len(sorted_lum) * 0.05)
    upper_idx = int(len(sorted_lum) * 0.95)
    mid_range = sorted_lum[lower_idx:upper_idx]

    # 中间调平均亮度
    current_brightness = mid_range.mean()

    print(f"  当前中间调亮度: {current_brightness:.4f}")
    print(f"  目标亮度: {target_brightness:.4f}")

    # 5. 计算最终曝光补偿
    if current_brightness > 0:
        histogram_compensation = target_brightness / current_brightness
    else:
        histogram_compensation = 1.0

    final_exposure = base_exposure * histogram_compensation

    # 限制范围（避免过曝或过暗）
    final_exposure = np.clip(final_exposure, 0.3, 5.0)

    print(f"  最终曝光补偿: {final_exposure:.3f}")

    return final_exposure


def apply_tone_mapping_improved(image, method='aces', exposure=1.0):
    """
    改进的色调映射（更多方法，更准确）

    Args:
        image: 线性 RGB [0, inf]
        method: 'aces' | 'aces_approx' | 'uncharted2' | 'reinhard_extended' | 'hable' | 'exposure'
        exposure: 曝光补偿
    """
    # 曝光调整
    img = image * exposure

    if method == 'exposure':
        # 简单曝光 + Gamma（最亮）
        return np.power(np.clip(img, 0, 1), 1.0 / 2.2)

    elif method == 'aces':
        # ACES Filmic (Academy Color Encoding System)
        # 电影工业标准，亮度平衡最好
        def aces_fitted(x):
            a = 2.51
            b = 0.03
            c = 2.43
            d = 0.59
            e = 0.14
            return np.clip((x * (a * x + b)) / (x * (c * x + d) + e), 0, 1)

        return aces_fitted(img)

    elif method == 'aces_approx':
        # ACES 近似（更快）
        def aces_approx(x):
            x = x * 0.6  # Pre-exposure
            a = 2.51
            b = 0.03
            c = 2.43
            d = 0.59
            e = 0.14
            return (x * (a * x + b)) / (x * (c * x + d) + e)

        return np.clip(aces_approx(img), 0, 1)

    elif method == 'uncharted2':
        # Uncharted 2 (原来的 filmic)
        # 高光保留好，但整体偏暗
        def uncharted2_tonemap(x):
            A, B, C, D, E, F = 0.22, 0.30, 0.10, 0.20, 0.01, 0.30
            return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F

        white_point = 11.2
        mapped = uncharted2_tonemap(img * 2.0) / uncharted2_tonemap(white_point)
        return mapped

    elif method == 'hable':
        # John Hable's Filmic (改进版 Uncharted 2)
        def hable_tonemap(x):
            A = 0.15
            B = 0.50
            C = 0.10
            D = 0.20
            E = 0.02
            F = 0.30
            return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F

        white_point = 11.2
        curr = hable_tonemap(img * 2.0)
        white = hable_tonemap(white_point)
        return curr / white

    elif method == 'reinhard':
        # 原始 Reinhard（全局）
        return img / (1.0 + img)

    elif method == 'reinhard_extended':
        # Extended Reinhard（保留高光细节更好）
        L_white = 4.0  # 白点亮度
        return (img * (1.0 + img / (L_white**2))) / (1.0 + img)

    elif method == 'lottes':
        # Timothy Lottes tone mapping (Nvidia)
        # 对比度好，亮度平衡
        def lottes_tonemap(x):
            a = 1.6
            d = 0.977
            hdrMax = 8.0
            midIn = 0.18
            midOut = 0.267

            b = (-pow(midIn, a) + pow(hdrMax, a) * midOut) / ((pow(hdrMax, a * d) - pow(midIn, a * d)) * midOut)
            c = (pow(hdrMax, a * d) * pow(midIn, a) - pow(hdrMax, a) * pow(midIn, a * d) * midOut) / (
                (pow(hdrMax, a * d) - pow(midIn, a * d)) * midOut
            )

            return pow(x, a) / (pow(x, a * d) * b + c)

        return np.clip(lottes_tonemap(img), 0, 1)

    else:
        raise ValueError(f"Unknown tone mapping method: {method}")


def unsharp_mask(image, sigma=1.0, strength=1.5):
    """
    反锐化掩模
    """
    from scipy.ndimage import gaussian_filter

    blurred = np.zeros_like(image)
    for i in range(3):
        blurred[:, :, i] = gaussian_filter(image[:, :, i], sigma=sigma)

    # 高频成分
    high_freq = image - blurred

    # 增强
    sharpened = image + strength * high_freq

    return np.clip(sharpened, 0, 1)


def convert_dng_to_srgb(
    dng_path,
    output_path,
    use_camera_wb=True,
    iterative_wb=False,
    wb_iterations=2,
    tone_mapping='aces',
    auto_exposure=True,
    exposure=None,
    target_brightness=0.18,
    sharpen=True,
    sharpen_strength=1.2,
    quality=95,
):
    """
    DNG → sRGB JPEG 完整转换

    Args:
        dng_path: DNG 文件路径
        output_path: 输出 JPEG 路径
        use_camera_wb: 使用相机白平衡
        iterative_wb: 是否迭代优化白平衡
        wb_iterations: 白平衡迭代次数
        tone_mapping: 色调映射方法
        auto_exposure: 是否自动曝光分析
        exposure: 手动曝光补偿（None = 使用自动）
        target_brightness: 自动曝光的目标亮度
        sharpen: 是否锐化
        sharpen_strength: 锐化强度
        quality: JPEG 质量 (1-100)
    """
    print(f"处理: {dng_path}")

    # 1. 读取 DNG
    print("  [1/8] 读取 DNG...")
    with rawpy.imread(str(dng_path)) as raw:

        # 提取元数据
        metadata = load_dng_metadata(raw)
        print(f"  相机: {metadata['color_desc']}")
        print(f"  相机白平衡: {metadata['camera_wb']}")
        print(f"  白平衡增益: {metadata['wb_gains']}")

        # 2. 自动计算曝光（如果启用）
        if auto_exposure and exposure is None:
            print("  [2/8] 自动曝光分析...")
            exposure = calculate_auto_exposure(raw, dng_path, target_brightness=target_brightness)
        elif exposure is None:
            exposure = 1.0
            print(f"  [2/8] 使用默认曝光: {exposure}")
        else:
            print(f"  [2/8] 使用手动曝光: {exposure}")

        # 3. RAW → RGB（线性空间）
        print("  [3/8] RAW 解码...")

        params = rawpy.Params(
            use_camera_wb=use_camera_wb,
            use_auto_wb=False,
            output_color=rawpy.ColorSpace.sRGB,
            output_bps=16,
            no_auto_bright=True,
            gamma=(1, 1),  # 线性，不应用 gamma
            demosaic_algorithm=rawpy.DemosaicAlgorithm.AHD,  # 高质量去马赛克
        )

        rgb = raw.postprocess(params)

        # 转换到浮点 [0, 1]
        rgb_float = rgb.astype(np.float32) / 65535.0

        print(f"  图像尺寸: {rgb_float.shape[1]}x{rgb_float.shape[0]}")
        print(f"  动态范围: {rgb_float.min():.4f} - {rgb_float.max():.4f}")

    # 4. 迭代白平衡优化（可选）
    if iterative_wb:
        print(f"  [4/8] 迭代白平衡优化 ({wb_iterations} 次)...")
        rgb_float = iterative_white_balance(rgb_float, initial_wb=metadata['wb_gains'], max_iter=wb_iterations)
    else:
        print("  [4/8] 跳过迭代白平衡")

    # 5. 色调映射
    print(f"  [5/8] 色调映射 (方法: {tone_mapping}, 曝光: {exposure:.3f})...")
    rgb_mapped = apply_tone_mapping_improved(rgb_float, method=tone_mapping, exposure=exposure)

    # 6. Gamma 校正（sRGB）
    print("  [6/8] Gamma 校正...")
    rgb_gamma = np.power(rgb_mapped, 1.0 / 2.2)

    # 7. 锐化（可选）
    if sharpen:
        print(f"  [7/8] 锐化 (强度: {sharpen_strength})...")
        rgb_gamma = unsharp_mask(rgb_gamma, sigma=1.0, strength=sharpen_strength)
    else:
        print("  [7/8] 跳过锐化")

    # 8. 转换到 8-bit 并保存
    print(f"  [8/8] 保存 JPEG (质量: {quality})...")
    rgb_8bit = (np.clip(rgb_gamma, 0, 1) * 255).astype(np.uint8)

    imageio.imwrite(output_path, rgb_8bit, quality=quality)

    print(f"✓ 完成: {output_path}")
    print(f"  最终尺寸: {rgb_8bit.shape[1]}x{rgb_8bit.shape[0]}")
    print()


def batch_convert(input_dir, output_dir, **kwargs):
    """
    批量转换目录中的所有 DNG
    """
    input_path = Path(input_dir)
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)

    dng_files = list(input_path.glob('*.dng')) + list(input_path.glob('*.DNG'))

    print(f"找到 {len(dng_files)} 个 DNG 文件")
    print()

    for i, dng_file in enumerate(dng_files, 1):
        output_file = output_path / f"{dng_file.stem}.jpg"
        print(f"[{i}/{len(dng_files)}]")

        try:
            convert_dng_to_srgb(dng_file, output_file, **kwargs)
        except Exception as e:
            print(f"✗ 错误: {e}")
            print()
            continue


def main():
    parser = argparse.ArgumentParser(
        description='DNG to sRGB JPEG Converter',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  # 单文件转换（自动曝光 + ACES）
  python x3-dng-to-jpg.py input.dng -o output.jpg
  
  # 批量转换
  python x3-dng-to-jpg.py input_dir/ -o output_dir/
  
  # 手动曝光
  python x3-dng-to-jpg.py input.dng -o output.jpg --exposure 2.5
  
  # 完整参数
  python x3-dng-to-jpg.py input.dng -o output.jpg \\
    --iterative-wb \\
    --tone-mapping aces \\
    --exposure 2.0 \\
    --sharpen-strength 1.5 \\
    --quality 95
  
  # 对比不同色调映射
  python x3-dng-to-jpg.py input.dng -o aces.jpg --tone-mapping aces
  python x3-dng-to-jpg.py input.dng -o hable.jpg --tone-mapping hable
  python x3-dng-to-jpg.py input.dng -o lottes.jpg --tone-mapping lottes
        """,
    )

    parser.add_argument('input', help='输入 DNG 文件或目录')
    parser.add_argument('-o', '--output', required=True, help='输出 JPEG 文件或目录')

    # 白平衡选项
    wb_group = parser.add_argument_group('白平衡选项')
    wb_group.add_argument('--no-camera-wb', action='store_true', help='不使用相机白平衡')
    wb_group.add_argument('--iterative-wb', action='store_true', help='迭代优化白平衡')
    wb_group.add_argument('--wb-iterations', type=int, default=2, help='白平衡迭代次数 (默认: 2)')

    # 色调映射选项
    tone_group = parser.add_argument_group('色调映射选项')
    tone_group.add_argument(
        '--tone-mapping',
        choices=['aces', 'aces_approx', 'uncharted2', 'hable', 'reinhard', 'reinhard_extended', 'lottes', 'exposure'],
        default='aces',
        help='色调映射方法 (默认: aces，推荐)',
    )
    tone_group.add_argument('--no-auto-exposure', action='store_true', help='禁用自动曝光分析')
    tone_group.add_argument(
        '--exposure', type=float, default=None, help='手动曝光补偿（覆盖自动曝光），推荐值: 1.5-3.0'
    )
    tone_group.add_argument(
        '--target-brightness', type=float, default=0.18, help='目标中间调亮度，用于自动曝光 (默认: 0.18 = 18%% 灰)'
    )

    # 锐化选项
    sharp_group = parser.add_argument_group('锐化选项')
    sharp_group.add_argument('--sharpen', action='store_true', help='不锐化')
    sharp_group.add_argument('--sharpen-strength', type=float, default=1.2, help='锐化强度 (默认: 1.2)')

    # 输出选项
    output_group = parser.add_argument_group('输出选项')
    output_group.add_argument('--quality', type=int, default=95, help='JPEG 质量 1-100 (默认: 95)')

    args = parser.parse_args()

    # 转换参数
    convert_kwargs = {
        'use_camera_wb': not args.no_camera_wb,
        'iterative_wb': args.iterative_wb,
        'wb_iterations': args.wb_iterations,
        'tone_mapping': args.tone_mapping,
        'auto_exposure': not args.no_auto_exposure,
        'exposure': args.exposure,
        'target_brightness': args.target_brightness,
        'sharpen': args.sharpen,
        'sharpen_strength': args.sharpen_strength,
        'quality': args.quality,
    }

    # 判断是单文件还是批量
    input_path = Path(args.input)

    if input_path.is_file():
        convert_dng_to_srgb(input_path, args.output, **convert_kwargs)
    elif input_path.is_dir():
        batch_convert(input_path, args.output, **convert_kwargs)
    else:
        print(f"错误: {args.input} 不存在")
        return 1

    return 0


if __name__ == '__main__':
    exit(main())
