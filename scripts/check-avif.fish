#!/usr/bin/env fish

set -l file $argv[1]

if test -z "$file"
    echo "用法: fish scripts/check-avif.fish /path/to/file.avif"
    exit 1
end

if not test -f "$file"
    echo "文件不存在: $file"
    exit 1
end

if not command -q exiftool
    echo "缺少 exiftool: brew install exiftool"
    exit 1
end

function joined_or_none
    if test (count $argv) -eq 0
        echo "(none)"
        return
    end

    string join " | " $argv
end

echo "== 文件 =="
echo "$file"
echo

echo "== AVIF 元数据 =="
exiftool -a -G1 -s \
    -FileType \
    -MIMEType \
    -ImageWidth \
    -ImageHeight \
    -MajorBrand \
    -CompatibleBrands \
    -ColorProfiles \
    -ColorSpace \
    -ProfileDescription \
    -ColorSpaceData \
    -ProfileConnectionSpace \
    -ColorPrimaries \
    -TransferCharacteristics \
    -MatrixCoefficients \
    -VideoFullRangeFlag \
    -ImagePixelDepth \
    -ChromaFormat \
    -ChromaSamplePosition \
    -AuxiliaryImageType \
    -PrimaryItemReference \
    -ImageSpatialExtent \
    "$file"
echo

set -l metadata (exiftool -a -s -s -s \
    -ColorProfiles \
    -ColorSpace \
    -ProfileDescription \
    -ColorSpaceData \
    -ProfileConnectionSpace \
    -ColorPrimaries \
    -TransferCharacteristics \
    -MatrixCoefficients \
    -VideoFullRangeFlag \
    -ImagePixelDepth \
    "$file")
set -l color_primaries (exiftool -a -s -s -s -ColorPrimaries "$file")
set -l transfer_characteristics (exiftool -a -s -s -s -TransferCharacteristics "$file")
set -l matrix_coefficients (exiftool -a -s -s -s -MatrixCoefficients "$file")
set -l video_full_range (exiftool -a -s -s -s -VideoFullRangeFlag "$file")
set -l auxiliary_image_types (exiftool -a -s -s -s -AuxiliaryImageType "$file")
set -l image_pixel_depths (exiftool -a -s -s -s -ImagePixelDepth "$file")

echo "== 色彩信令摘要 =="
echo "Primaries : "(joined_or_none $color_primaries)
echo "Transfer  : "(joined_or_none $transfer_characteristics)
echo "Matrix    : "(joined_or_none $matrix_coefficients)
echo "Range     : "(joined_or_none $video_full_range)
echo

echo "== 判断 =="

set -l has_bt2020_primaries 0
set -l has_p3_primaries 0
set -l has_srgb_or_bt709_primaries 0
set -l has_hdr_transfer 0
set -l has_sdr_transfer 0
set -l has_bt2020_matrix 0
set -l has_bt709_matrix 0

if string match -qi "*bt.2020*" -- $color_primaries
    set has_bt2020_primaries 1
end

if string match -qi "*p3*" -- $color_primaries; or string match -qi "*smpte*432*" -- $color_primaries
    set has_p3_primaries 1
end

if string match -qi "*bt.709*" -- $color_primaries; or string match -qi "*srgb*" -- $color_primaries
    set has_srgb_or_bt709_primaries 1
end

if string match -qi "*hlg*" -- $transfer_characteristics; or string match -qi "*pq*" -- $transfer_characteristics; or string match -qi "*2084*" -- $transfer_characteristics; or string match -qi "*arib*" -- $transfer_characteristics
    set has_hdr_transfer 1
end

if string match -qi "*srgb*" -- $transfer_characteristics; or string match -qi "*iec*" -- $transfer_characteristics
    set has_sdr_transfer 1
end

if string match -qi "*bt.2020 non-constant*" -- $matrix_coefficients
    set has_bt2020_matrix 1
end

if string match -qi "*bt.709*" -- $matrix_coefficients
    set has_bt709_matrix 1
end

if test $has_bt2020_primaries -eq 1
    echo "OK: ColorPrimaries 是 BT.2020/BT.2100"
else if test $has_p3_primaries -eq 1
    echo "OK: ColorPrimaries 是 Display P3"
else if test $has_srgb_or_bt709_primaries -eq 1
    echo "OK: ColorPrimaries 是 sRGB/BT.709"
else
    echo "WARN: ColorPrimaries 未识别为 BT.2020、Display P3 或 sRGB/BT.709"
end

if test $has_hdr_transfer -eq 1
    echo "OK: TransferCharacteristics 是 HDR 传递函数"
else if test $has_sdr_transfer -eq 1
    echo "OK: TransferCharacteristics 是 SDR/sRGB 传递函数"
else
    echo "WARN: TransferCharacteristics 未看到 HLG/PQ/sRGB"
end

if test $has_bt2020_primaries -eq 1; and test $has_hdr_transfer -eq 1
    if test $has_bt2020_matrix -eq 1
        echo "OK: Rec.2020 HDR 使用 BT.2020 non-constant matrix"
    else if test $has_bt709_matrix -eq 1
        echo "BAD: Rec.2020 HDR 使用 BT.709 matrix，浏览器 HDR 兼容风险高"
    else
        echo "WARN: Rec.2020 HDR 的 matrix 未确认是 BT.2020 non-constant"
    end
else if test $has_p3_primaries -eq 1; and test $has_hdr_transfer -eq 1
    if test $has_bt709_matrix -eq 1
        echo "OK: Display P3 HDR 使用 BT.709 matrix"
    else
        echo "WARN: Display P3 HDR 的 matrix 不是常见 BT.709"
    end
else if test $has_sdr_transfer -eq 1
    if test $has_bt709_matrix -eq 1
        echo "OK: SDR AVIF 使用 BT.709 matrix"
    else
        echo "WARN: SDR AVIF 的 matrix 不是常见 BT.709"
    end
else
    echo "WARN: 无法判断 matrix 是否符合当前色彩预设"
end

if string match -qi "*full*" -- $video_full_range
    echo "OK: VideoFullRangeFlag 是 Full"
else
    echo "WARN: VideoFullRangeFlag 未看到 Full"
end

if string match -q "*10 10 10*" -- $metadata
    echo "OK: ImagePixelDepth 是 10-bit RGB"
else
    echo "WARN: ImagePixelDepth 未看到 10 10 10"
end

if string match -q "*8*" -- $image_pixel_depths
    echo "WARN: 同时存在 8-bit 图像项，可能是 alpha/gain-map 辅助图"
end

if test (count $auxiliary_image_types) -gt 0
    echo "BAD: 存在 AuxiliaryImageType: "(string join ", " $auxiliary_image_types)
else
    echo "OK: 未看到 AuxiliaryImageType"
end

if command -q ffprobe
    echo
    echo "== ffprobe 摘要 =="
    set -l ffprobe_metadata (ffprobe -hide_banner -v error \
        -select_streams v:0 \
        -show_entries stream=pix_fmt,color_range,color_space,color_transfer,color_primaries,width,height \
        -of default=noprint_wrappers=1 \
        "$file")

    printf "%s\n" $ffprobe_metadata

    echo
    echo "== AV1 bitstream 判断 =="
    if string match -q "*color_space=bt2020nc*" -- $ffprobe_metadata
        if test $has_bt2020_primaries -eq 1
            echo "OK: AV1 bitstream color_space 是 bt2020nc"
        else
            echo "WARN: AV1 bitstream color_space 是 bt2020nc，但容器 primaries 不是 BT.2020"
        end
    else if string match -q "*color_space=bt709*" -- $ffprobe_metadata
        if test $has_bt2020_primaries -eq 1; and test $has_hdr_transfer -eq 1
            echo "BAD: AV1 bitstream color_space 是 bt709，Rec.2020 HDR 兼容风险高"
        else
            echo "OK: AV1 bitstream color_space 是 bt709，适合 sRGB/P3"
        end
    else
        echo "WARN: AV1 bitstream color_space 未确认"
    end

    if string match -q "*color_primaries=bt2020*" -- $ffprobe_metadata
        echo "OK: AV1 bitstream color_primaries 是 bt2020"
    else if string match -q "*color_primaries=smpte432*" -- $ffprobe_metadata
        echo "OK: AV1 bitstream color_primaries 是 Display P3/smpte432"
    else if string match -q "*color_primaries=bt709*" -- $ffprobe_metadata
        echo "OK: AV1 bitstream color_primaries 是 bt709"
    else
        echo "WARN: AV1 bitstream color_primaries 未确认"
    end

    if string match -q "*color_transfer=smpte2084*" -- $ffprobe_metadata
        echo "OK: AV1 bitstream transfer 是 PQ"
    else if string match -q "*color_transfer=arib-std-b67*" -- $ffprobe_metadata
        echo "OK: AV1 bitstream transfer 是 HLG"
    else if string match -q "*color_transfer=iec61966-2-1*" -- $ffprobe_metadata
        echo "OK: AV1 bitstream transfer 是 sRGB"
    else
        echo "WARN: AV1 bitstream transfer 未确认"
    end
else
    echo
    echo "提示: 安装 ffmpeg 后可用 ffprobe 交叉检查: brew install ffmpeg"
end
