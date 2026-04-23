#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "exifread",
#     "imageio",
#     "numpy",
#     "rawpy",
#     "scipy",
# ]
# ///
"""
DNG to sRGB JPEG Converter
支持普通 Bayer 和 Foveon X3F DNG

brew install exiftool
exiftool -a -G1 DP3Q0109.X3F.dng | grep -iE "white|balance|neutral|illuminant|color|temp|tint|shutter|aperture|speed"
"""

import argparse
from pathlib import Path

import imageio
import numpy as np
import rawpy

try:
    import exifread
except ImportError:
    exifread = None


DEFAULT_TARGET_BRIGHTNESS = 0.18
DEFAULT_SHARPEN_SIGMA = 1.0
DEFAULT_SHARPEN_STRENGTH = 1.2


def parse_exif_rational(tag_value):
    """
    解析 EXIF 中的有理数或浮点数字段
    """
    if tag_value is None:
        return None

    try:
        tag_text = str(tag_value).strip()

        if '/' in tag_text:
            numerator_text, denominator_text = tag_text.split('/', 1)
            denominator = float(denominator_text)

            if denominator == 0:
                return None

            return float(numerator_text) / denominator

        return float(tag_text)
    except (TypeError, ValueError, ZeroDivisionError):
        return None


def calculate_auto_exposure(raw, dng_path, target_brightness=DEFAULT_TARGET_BRIGHTNESS):
    """
    根据 EXIF 和图像直方图自动计算曝光补偿

    Args:
        raw: rawpy 对象
        target_brightness: 目标中间调亮度 (0.18 = 18% 灰)

    Returns:
        exposure_compensation: 曝光补偿系数
    """
    # 1. 从 EXIF 读取曝光参数，仅用于日志
    if exifread is None:
        print('  未安装 exifread，跳过 EXIF 读取')
    else:
        try:
            with open(dng_path, 'rb') as file_object:
                tags = exifread.process_file(file_object, details=False)

            iso = parse_exif_rational(tags.get('EXIF ISOSpeedRatings') or tags.get('Image ISO Speed Ratings'))
            exp_time = parse_exif_rational(tags.get('EXIF ExposureTime'))
            aperture = parse_exif_rational(tags.get('EXIF FNumber'))
            ev_compensation = parse_exif_rational(tags.get('EXIF ExposureBiasValue'))

            parts = []
            if iso is not None:
                parts.append(f'ISO{int(round(iso))}')
            if exp_time is not None:
                parts.append(f'{exp_time:.4f}s')
            if aperture is not None:
                parts.append(f'f/{aperture:.1f}')
            if ev_compensation is not None and abs(ev_compensation) > 1e-6:
                parts.append(f'{ev_compensation:+.1f}EV')

            if parts:
                print(f"  EXIF: {', '.join(parts)}")
        except Exception as error:
            print(f'  无法读取 EXIF: {error}')

    # 2. 分析图像直方图
    # 快速处理一个小图来分析亮度
    params = rawpy.Params(
        use_camera_wb=True,
        output_bps=16,
        gamma=(1, 1),  # 线性
        no_auto_bright=True,
        half_size=True,
    )

    preview = raw.postprocess(params)
    preview_float = preview.astype(np.float32) / 65535.0

    # 计算亮度（使用 Rec. 709 系数）
    luminance = (
        0.2126 * preview_float[:, :, 0]
        + 0.7152 * preview_float[:, :, 1]
        + 0.0722 * preview_float[:, :, 2]
    )

    # 去除过亮和过暗区域（前后 5%）
    lower, upper = np.percentile(luminance, [5, 95])
    mid_range_mask = (luminance > lower) & (luminance < upper)

    # 中间调平均亮度
    if mid_range_mask.any():
        current_brightness = float(luminance[mid_range_mask].mean())
    else:
        current_brightness = float(luminance.mean())

    # 3. 计算最终曝光补偿
    if current_brightness <= 1e-6:
        final_exposure = 1.0
    else:
        final_exposure = target_brightness / current_brightness

    # 限制范围，避免极端输入放大误差
    final_exposure = np.clip(final_exposure, 0.3, 5.0)

    print(f"  曝光: {final_exposure:.2f} (目标亮度: {target_brightness:.2f}, 当前: {current_brightness:.2f})")

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
        # 简单曝光，仅做裁剪，Gamma 在后续统一处理
        return np.clip(img, 0, 1)

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
            hdr_max = 8.0
            mid_in = 0.18
            mid_out = 0.267

            b = (-np.power(mid_in, a) + np.power(hdr_max, a) * mid_out) / (
                (np.power(hdr_max, a * d) - np.power(mid_in, a * d)) * mid_out
            )
            c = (
                np.power(hdr_max, a * d) * np.power(mid_in, a)
                - np.power(hdr_max, a) * np.power(mid_in, a * d) * mid_out
            ) / (
                (np.power(hdr_max, a * d) - np.power(mid_in, a * d)) * mid_out
            )

            return np.power(x, a) / (np.power(x, a * d) * b + c)

        return np.clip(lottes_tonemap(img), 0, 1)

    else:
        raise ValueError(f"Unknown tone mapping method: {method}")


def unsharp_mask(image, sigma=1.0, strength=1.5):
    """
    反锐化掩模
    """
    from scipy.ndimage import gaussian_filter

    blurred = gaussian_filter(image, sigma=(sigma, sigma, 0))

    # 高频成分
    high_freq = image - blurred

    # 增强
    sharpened = image + strength * high_freq

    return np.clip(sharpened, 0, 1)


def convert_dng_to_srgb(
    dng_path,
    output_path,
    tone_mapping='aces',
    exposure=None,
    sharpen=True,
    quality=95,
):
    """
    DNG → sRGB JPEG 完整转换

    Args:
        dng_path: DNG 文件路径
        output_path: 输出 JPEG 路径
        tone_mapping: 色调映射方法
        exposure: 手动曝光补偿（None = 使用自动）
        sharpen: 是否锐化
        quality: JPEG 质量 (1-100)
    """
    print(f"处理: {dng_path}")

    # 1. 读取 DNG
    print("  [1/6] 读取 DNG 元数据")
    with rawpy.imread(str(dng_path)) as raw:
        # 2. 自动计算曝光（未提供手动曝光时）
        if exposure is None:
            print("  [2/6] 自动曝光分析")
            exposure = calculate_auto_exposure(raw, dng_path)
        else:
            print(f"  [2/6] 使用手动曝光: {exposure}")

        # 3. RAW → RGB（线性空间）
        print("  [3/6] RAW 解码 (去马赛克 AHD, 线性空间, 相机白平衡)")
        params = rawpy.Params(
            use_camera_wb=True,
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
        print(f"      尺寸: {rgb_float.shape[1]}x{rgb_float.shape[0]}, 范围: [{rgb_float.min():.3f}, {rgb_float.max():.3f}]")

    # 4. 色调映射
    print(f"  [4/6] 色调映射 ({tone_mapping}, 曝光系数: {exposure:.2f})")
    rgb_mapped = apply_tone_mapping_improved(rgb_float, method=tone_mapping, exposure=exposure)
    rgb_mapped = np.clip(rgb_mapped, 0, None)

    # 5. Gamma 校正（sRGB）
    print("  [5/6] Gamma 2.2 校正")
    rgb_gamma = np.power(rgb_mapped, 1.0 / 2.2)

    # 6. 锐化（可选）
    if sharpen:
        print(f"  [6/6] 反锐化掩模 (强度: {DEFAULT_SHARPEN_STRENGTH})")
        rgb_gamma = unsharp_mask(rgb_gamma, sigma=DEFAULT_SHARPEN_SIGMA, strength=DEFAULT_SHARPEN_STRENGTH)
    else:
        print("  [6/6] 跳过锐化")

    # 8. 保存
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    rgb_8bit = (np.clip(rgb_gamma, 0, 1) * 255).astype(np.uint8)
    imageio.imwrite(output_path, rgb_8bit, quality=quality)

    print(f"✓ 完成: {output_path} (JPEG 质量: {quality})")
    print()


def batch_convert(input_dir, output_dir, **kwargs):
    """
    批量转换目录中的所有 DNG
    """
    input_path = Path(input_dir)
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)

    dng_files = sorted({*input_path.glob('*.dng'), *input_path.glob('*.DNG')})

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
  ./x3-dng-to-jpg.py input.dng -o output.jpg
  
  # 批量转换
  ./x3-dng-to-jpg.py input_dir/ -o output_dir/
  
  # 手动曝光
  ./x3-dng-to-jpg.py input.dng -o output.jpg --exposure 2.5
  
  # 完整参数
  ./x3-dng-to-jpg.py input.dng -o output.jpg \\
    --tone-mapping aces \\
    --exposure 2.0 \\
    --quality 95
  
  # 对比不同色调映射
  ./x3-dng-to-jpg.py input.dng -o aces.jpg --tone-mapping aces
  ./x3-dng-to-jpg.py input.dng -o hable.jpg --tone-mapping hable
  ./x3-dng-to-jpg.py input.dng -o lottes.jpg --tone-mapping lottes
        """,
    )

    parser.add_argument('input', help='输入 DNG 文件或目录')
    parser.add_argument('-o', '--output', required=True, help='输出 JPEG 文件或目录')

    # 色调映射选项
    tone_group = parser.add_argument_group('色调映射选项')
    tone_group.add_argument(
        '--tone-mapping',
        choices=['aces', 'aces_approx', 'uncharted2', 'hable', 'reinhard', 'reinhard_extended', 'lottes', 'exposure'],
        default='aces',
        help='色调映射方法 (默认: aces，推荐)',
    )
    tone_group.add_argument(
        '--exposure', type=float, default=None, help='手动曝光补偿（覆盖自动曝光），推荐值: 1.5-3.0'
    )

    # 锐化选项
    sharp_group = parser.add_argument_group('锐化选项')
    sharp_group.add_argument('--sharpen', dest='sharpen', action='store_true', default=True, help=argparse.SUPPRESS)
    sharp_group.add_argument('--no-sharpen', dest='sharpen', action='store_false', help='禁用锐化')

    # 输出选项
    output_group = parser.add_argument_group('输出选项')
    output_group.add_argument('--quality', type=int, default=95, help='JPEG 质量 1-100 (默认: 95)')

    args = parser.parse_args()

    if not 1 <= args.quality <= 100:
        parser.error('--quality 必须在 1 到 100 之间')

    if args.exposure is not None and args.exposure <= 0:
        parser.error('--exposure 必须大于 0')

    # 转换参数
    convert_kwargs = {
        'tone_mapping': args.tone_mapping,
        'exposure': args.exposure,
        'sharpen': args.sharpen,
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
