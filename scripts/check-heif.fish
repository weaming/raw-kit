#!/usr/bin/env fish

set -l file $argv[1]

if test -z "$file"
    echo "用法: fish scripts/check-heif.fish /path/to/file.heic"
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

echo "== HEIF 元数据 =="
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
    -MaxContentLightLevel \
    -MaxPicAverageLightLevel \
    -ImageSpatialExtent \
    -ImagePixelDepth \
    -ChromaFormat \
    -BitDepthLuma \
    -BitDepthChroma \
    -PrimaryItemReference \
    -MetaImageSize \
    -ImageDescription \
    -Software \
    -TileWidth \
    -TileLength \
    -Warning \
    "$file"
echo

set -l file_type (exiftool -a -s -s -s -FileType "$file")
set -l mime_type (exiftool -a -s -s -s -MIMEType "$file")
set -l color_profiles (exiftool -a -s -s -s -ColorProfiles "$file")
set -l color_primaries (exiftool -a -s -s -s -ColorPrimaries "$file")
set -l transfer_characteristics (exiftool -a -s -s -s -TransferCharacteristics "$file")
set -l matrix_coefficients (exiftool -a -s -s -s -MatrixCoefficients "$file")
set -l video_full_range (exiftool -a -s -s -s -VideoFullRangeFlag "$file")
set -l image_pixel_depths (exiftool -a -s -s -s -ImagePixelDepth "$file")
set -l bit_depth_luma (exiftool -a -s -s -s -BitDepthLuma "$file")
set -l bit_depth_chroma (exiftool -a -s -s -s -BitDepthChroma "$file")
set -l max_content_light_level (exiftool -a -s -s -s -MaxContentLightLevel "$file")
set -l max_pic_average_light_level (exiftool -a -s -s -s -MaxPicAverageLightLevel "$file")
set -l image_description (exiftool -a -s -s -s -ImageDescription "$file")
set -l xmp_fields (exiftool -a -G1 -s -XMP:all "$file")
set -l icc_profile_description (exiftool -a -s -s -s -ICC_Profile:ProfileDescription "$file")

echo "== 色彩信令摘要 =="
echo "Profiles  : "(joined_or_none $color_profiles)
echo "Primaries : "(joined_or_none $color_primaries)
echo "Transfer  : "(joined_or_none $transfer_characteristics)
echo "Matrix    : "(joined_or_none $matrix_coefficients)
echo "Range     : "(joined_or_none $video_full_range)
echo "CLLI      : MaxCLL="(joined_or_none $max_content_light_level)" MaxFALL="(joined_or_none $max_pic_average_light_level)
echo

echo "== 判断 =="

if string match -qi "*HEIF*" -- $file_type; or string match -qi "*heif*" -- $mime_type; or string match -qi "*heic*" -- $mime_type
    echo "OK: 文件是 HEIF/HEIC"
else
    echo "BAD: 文件类型不是 HEIF/HEIC"
end

if string match -qi "*nclx*" -- $color_profiles
    echo "OK: 使用 nclx 色彩配置"
else
    echo "WARN: 未看到 nclx 色彩配置"
end

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
        echo "OK: SDR HEIF 使用 BT.709 matrix"
    else
        echo "WARN: SDR HEIF 的 matrix 不是常见 BT.709"
    end
else
    echo "WARN: 无法判断 matrix 是否符合当前色彩预设"
end

if string match -qi "*full*" -- $video_full_range
    echo "OK: VideoFullRangeFlag 是 Full"
else
    echo "WARN: VideoFullRangeFlag 未看到 Full"
end

if string match -q "*10 10 10*" -- $image_pixel_depths; or test "$bit_depth_luma" = "10"; and test "$bit_depth_chroma" = "10"
    echo "OK: 图像是 10-bit"
else
    echo "WARN: 未确认是 10-bit"
end

if test -z "$image_description"
    echo "OK: 未看到 ImageDescription"
else
    echo "BAD: 仍存在 ImageDescription: "(joined_or_none $image_description)
end

if test -n "$max_content_light_level"
    if test "$max_pic_average_light_level" = "0"
        echo "WARN: CLLI 存在，但 MaxFALL 为 0"
    else if test -n "$max_pic_average_light_level"
        echo "OK: CLLI 包含 MaxCLL 和 MaxFALL"
    else
        echo "WARN: CLLI 存在，但未读取到 MaxFALL"
    end
else
    echo "OK: 未看到 CLLI"
end

if command -q heif-info
    echo
    echo "== heif-info =="
    heif-info "$file"
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
    echo "== HEVC bitstream 判断 =="
    if string match -q "*color_space=bt2020nc*" -- $ffprobe_metadata
        if test $has_bt2020_primaries -eq 1
            echo "OK: HEVC bitstream color_space 是 bt2020nc"
        else
            echo "WARN: HEVC bitstream color_space 是 bt2020nc，但容器 primaries 不是 BT.2020"
        end
    else if string match -q "*color_space=bt709*" -- $ffprobe_metadata
        if test $has_bt2020_primaries -eq 1; and test $has_hdr_transfer -eq 1
            echo "BAD: HEVC bitstream color_space 是 bt709，Rec.2020 HDR 兼容风险高"
        else
            echo "OK: HEVC bitstream color_space 是 bt709，适合 sRGB/P3"
        end
    else
        echo "WARN: HEVC bitstream color_space 未确认"
    end

    if string match -q "*color_transfer=smpte2084*" -- $ffprobe_metadata
        echo "OK: HEVC bitstream transfer 是 PQ"
    else if string match -q "*color_transfer=arib-std-b67*" -- $ffprobe_metadata
        echo "OK: HEVC bitstream transfer 是 HLG"
    else if string match -q "*color_transfer=iec61966-2-1*" -- $ffprobe_metadata
        echo "OK: HEVC bitstream transfer 是 sRGB"
    else
        echo "WARN: HEVC bitstream transfer 未确认"
    end

    if string match -q "*color_primaries=bt2020*" -- $ffprobe_metadata
        echo "OK: HEVC bitstream primaries 是 bt2020"
    else if string match -q "*color_primaries=smpte432*" -- $ffprobe_metadata
        echo "OK: HEVC bitstream primaries 是 Display P3/smpte432"
    else if string match -q "*color_primaries=bt709*" -- $ffprobe_metadata
        echo "OK: HEVC bitstream primaries 是 bt709"
    else
        echo "WARN: HEVC bitstream primaries 未确认"
    end
else
    echo
    echo "跳过 ffprobe 检查：未安装 ffprobe"
end

if command -q strings
    echo
    echo "== 附加结构扫描 =="
    set -l string_metadata (strings "$file")
    set -l gain_map_hits (string match -ri ".*gain.?map|hdrgm.*" -- $string_metadata)
    set -l mpf_hits (string match -r ".*MPF.*" -- $string_metadata)

    if test (count $xmp_fields) -gt 0
        echo "INFO: 包含普通 XMP 元数据: "(count $xmp_fields)" 项"
    else
        echo "OK: 未看到 XMP 元数据"
    end

    if test (count $icc_profile_description) -gt 0
        echo "WARN: 包含 ICC Profile: "(joined_or_none $icc_profile_description)
    else
        echo "OK: 未看到 ICC Profile"
    end

    if test (count $gain_map_hits) -gt 0
        echo "WARN: 看到 gain map / hdrgm 字符串: "(count $gain_map_hits)
    else
        echo "OK: 未看到 gain map / hdrgm 字符串"
    end

    if test (count $mpf_hits) -gt 0
        echo "WARN: 看到 MPF 字符串: "(count $mpf_hits)
    else
        echo "OK: 未看到 MPF 字符串"
    end
end

echo
echo "== ExifTool validate =="
exiftool -validate -warning -error -G1 -a -s "$file"
