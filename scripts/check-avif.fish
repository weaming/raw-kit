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
    -ColorPrimaries \
    -TransferCharacteristics \
    -MatrixCoefficients \
    -VideoFullRangeFlag \
    -ImagePixelDepth \
    "$file")
set -l auxiliary_image_types (exiftool -a -s -s -s -AuxiliaryImageType "$file")
set -l image_pixel_depths (exiftool -a -s -s -s -ImagePixelDepth "$file")

echo "== 判断 =="

if string match -qi "*bt.2020*" -- $metadata
    echo "OK: ColorPrimaries 包含 BT.2020"
else
    echo "WARN: ColorPrimaries 未看到 BT.2020"
end

if string match -qi "*hlg*" -- $metadata; or string match -qi "*pq*" -- $metadata; or string match -qi "*2084*" -- $metadata
    echo "OK: TransferCharacteristics 是 HDR 传递函数"
else
    echo "WARN: TransferCharacteristics 未看到 HLG/PQ"
end

if string match -qi "*bt.2020 non-constant*" -- $metadata
    echo "OK: MatrixCoefficients 是 BT.2020 non-constant"
else if string match -qi "*bt.709*" -- $metadata
    echo "BAD: MatrixCoefficients 是 BT.709，Chrome HDR 兼容风险高"
else
    echo "WARN: MatrixCoefficients 未确认是 BT.2020 non-constant"
end

if string match -qi "*full*" -- $metadata
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
    ffprobe -hide_banner -v error \
        -select_streams v:0 \
        -show_entries stream=pix_fmt,color_range,color_space,color_transfer,color_primaries,width,height \
        -of default=noprint_wrappers=1 \
        "$file"
else
    echo
    echo "提示: 安装 ffmpeg 后可用 ffprobe 交叉检查: brew install ffmpeg"
end
