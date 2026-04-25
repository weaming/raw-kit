#!/usr/bin/env fish

set -l file $argv[1]

if test -z "$file"
    echo "用法: fish scripts/check-ultrahdr-jpeg.fish /path/to/file.jpg"
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

if not command -q strings
    echo "缺少 strings"
    exit 1
end

echo "== 文件 =="
echo "$file"
echo

echo "== JPEG 元数据 =="
exiftool -a -G1 -s \
    -FileType \
    -MIMEType \
    -ImageWidth \
    -ImageHeight \
    -BitsPerSample \
    -ColorComponents \
    -YCbCrSubSampling \
    -ColorSpace \
    -ProfileDescription \
    -UniformResourceName \
    -MPFVersion \
    -NumberOfImages \
    -MPImageFlags \
    -MPImageFormat \
    -MPImageType \
    -MPImageLength \
    -MPImageStart \
    -DependentImage1EntryNumber \
    -DependentImage2EntryNumber \
    -Warning \
    "$file"
echo

set -l metadata (exiftool -a -s -s -s \
    -FileType \
    -MIMEType \
    -UniformResourceName \
    -NumberOfImages \
    -MPImageType \
    -MPImageLength \
    -MPImageStart \
    -ProfileDescription \
    "$file")

set -l string_metadata (strings "$file")
set -l iso_gain_map_hits (string match -r ".*urn:iso:std:iso:ts:21496:-1.*" -- $string_metadata)
set -l hdrgm_hits (string match -ri ".*hdrgm.*" -- $string_metadata)
set -l xmp_hits (string match -ri ".*xmp.*" -- $string_metadata)
set -l gain_map_hits (string match -ri ".*gain.?map.*" -- $string_metadata)
set -l declared_image_starts (exiftool -a -s -s -s -MPImageStart "$file")
set -l actual_second_image_start (perl -e '
    use strict;
    use warnings;

    my $file = $ARGV[0];
    open my $handle, "<:raw", $file or exit 1;
    local $/;
    my $data = <$handle>;
    my $offset = 0;
    my @starts;

    while (($offset = index($data, "\xff\xd8", $offset)) >= 0) {
        push @starts, $offset;
        $offset += 2;
    }

    print $starts[1] if @starts > 1;
' "$file")

echo "== 字符串线索 =="
if test (count $iso_gain_map_hits) -gt 0
    echo "ISO 21496-1 URN: "(count $iso_gain_map_hits)
else
    echo "未看到 ISO 21496-1 URN"
end

if test (count $hdrgm_hits) -gt 0
    echo "hdrgm XMP: "(count $hdrgm_hits)
else
    echo "未看到 hdrgm XMP 命名空间"
end

if test (count $xmp_hits) -gt 0
    echo "XMP 字符串: "(count $xmp_hits)
else
    echo "未看到 XMP 字符串"
end

if test (count $gain_map_hits) -gt 0
    echo "gain map 字符串: "(count $gain_map_hits)
else
    echo "未看到 gain map 字符串"
end
echo

echo "== 判断 =="
if string match -qi "*JPEG*" -- $metadata
    echo "OK: 文件是 JPEG"
else
    echo "BAD: 文件类型不是 JPEG"
end

if string match -q "*urn:iso:std:iso:ts:21496:-1*" -- $metadata; or test (count $iso_gain_map_hits) -gt 0
    echo "OK: 包含 ISO 21496-1 gain map 元数据"
else
    echo "BAD: 未看到 ISO 21496-1 gain map 元数据"
end

if string match -q "*2*" -- (exiftool -a -s -s -s -NumberOfImages "$file")
    echo "OK: MPF 声明包含 2 张图像"
else
    echo "WARN: MPF 未确认包含 2 张图像"
end

if string match -qi "*Undefined*" -- (exiftool -a -s -s -s -MPImageType "$file")
    echo "OK: MPF 第二图像存在，通常是 gain map JPEG"
else
    echo "WARN: 未看到 MPF 第二图像"
end

if test -n "$actual_second_image_start"; and test (count $declared_image_starts) -ge 2
    if test "$declared_image_starts[2]" = "$actual_second_image_start"
        echo "OK: MPF 第二图像偏移匹配真实 JPEG SOI"
    else
        echo "BAD: MPF 第二图像偏移不匹配，声明 $declared_image_starts[2]，实际 $actual_second_image_start"
    end
else
    echo "WARN: 无法确认 MPF 第二图像偏移"
end

if test (count $hdrgm_hits) -gt 0
    echo "OK: 包含 hdrgm XMP 元数据"
else
    echo "BAD: 未看到 hdrgm XMP 元数据，Chrome/Android 兼容风险高"
end
echo

mkdir -p tmp
set -l temp_directory (mktemp -d tmp/check-ultrahdr.XXXXXX)

if test -n "$temp_directory"
    set -l gain_map_file "$temp_directory/gain-map.jpg"

    if exiftool -b -MPImage2 "$file" > "$gain_map_file" 2>/dev/null
        if test -s "$gain_map_file"
            echo "== MPF 第二图像 =="
            exiftool -a -G1 -s \
                -FileType \
                -MIMEType \
                -ImageWidth \
                -ImageHeight \
                -BitsPerSample \
                -ColorComponents \
                -YCbCrSubSampling \
                -XMP-hdrgm:Version \
                -XMP-hdrgm:GainMapMin \
                -XMP-hdrgm:GainMapMax \
                -XMP-hdrgm:Gamma \
                -XMP-hdrgm:OffsetSDR \
                -XMP-hdrgm:OffsetHDR \
                -XMP-hdrgm:HDRCapacityMin \
                -XMP-hdrgm:HDRCapacityMax \
                -XMP-hdrgm:BaseRenditionIsHDR \
                "$gain_map_file"
            echo

            set -l xmp_gain_map_min (exiftool -s -s -s -XMP-hdrgm:GainMapMin "$gain_map_file")
            set -l xmp_gain_map_max (exiftool -s -s -s -XMP-hdrgm:GainMapMax "$gain_map_file")
            set -l xmp_hdr_capacity_min (exiftool -s -s -s -XMP-hdrgm:HDRCapacityMin "$gain_map_file")
            set -l xmp_hdr_capacity_max (exiftool -s -s -s -XMP-hdrgm:HDRCapacityMax "$gain_map_file")
            set -l xmp_base_is_hdr (exiftool -s -s -s -XMP-hdrgm:BaseRenditionIsHDR "$gain_map_file")
            set -l gain_map_color_components (exiftool -s -s -s -ColorComponents "$gain_map_file")

            echo "== XMP gain map 判断 =="
            if test "$gain_map_color_components" = "1"
                echo "OK: gain map 子图是单通道"
            else
                echo "WARN: gain map 子图不是单通道，Chrome/Android 兼容风险较高"
            end

            if test -z "$xmp_gain_map_max"; or test -z "$xmp_hdr_capacity_max"
                echo "BAD: gain map 子图缺少必要 hdrgm XMP 数值"
            else
                set -l xmp_numeric_check (awk \
                    -v gain_min="$xmp_gain_map_min" \
                    -v gain_max="$xmp_gain_map_max" \
                    -v capacity_min="$xmp_hdr_capacity_min" \
                    -v capacity_max="$xmp_hdr_capacity_max" \
                    'BEGIN {
                        if (gain_min == "") gain_min = 0
                        if (capacity_min == "") capacity_min = 0

                        if (gain_min > 0) {
                            print "BAD: GainMapMin 大于 0，Ultra HDR v1 兼容风险高"
                        } else {
                            print "OK: GainMapMin 小于等于 0"
                        }

                        if (gain_max < gain_min) {
                            print "BAD: GainMapMax 小于 GainMapMin"
                        } else {
                            print "OK: GainMapMax 不小于 GainMapMin"
                        }

                        if (capacity_min < 0) {
                            print "BAD: HDRCapacityMin 小于 0"
                        } else {
                            print "OK: HDRCapacityMin 不小于 0"
                        }

                        if (capacity_max <= capacity_min) {
                            print "BAD: HDRCapacityMax 不大于 HDRCapacityMin"
                        } else {
                            print "OK: HDRCapacityMax 大于 HDRCapacityMin"
                        }

                        if (capacity_max > gain_max + 0.001) {
                            print "WARN: HDRCapacityMax 明显大于 GainMapMax，普通 HDR 显示器上增益可能偏弱"
                        } else {
                            print "OK: HDRCapacityMax 与 GainMapMax 对齐"
                        }
                    }')

                printf "%s\n" $xmp_numeric_check
            end

            if test "$xmp_base_is_hdr" = "False"; or test -z "$xmp_base_is_hdr"
                echo "OK: BaseRenditionIsHDR 为 False 或默认 False"
            else
                echo "BAD: BaseRenditionIsHDR 不是 False"
            end
            echo
        end
    end

    if command -q ultrahdr_app
        set -l decoded_raw_file "$temp_directory/decoded.raw"
        set -l gain_map_config_file "$temp_directory/gain-map.cfg"

        ultrahdr_app -m 1 \
            -j "$file" \
            -f "$gain_map_config_file" \
            -z "$decoded_raw_file" >/dev/null 2>&1

        if test $status -eq 0
            echo "== ultrahdr_app gain map 元数据 =="
            if test -s "$gain_map_config_file"
                cat "$gain_map_config_file"

                set -l decoded_max_content_boost (awk '/^--maxContentBoost / { print $2; exit }' "$gain_map_config_file")
                set -l decoded_min_content_boost (awk '/^--minContentBoost / { print $2; exit }' "$gain_map_config_file")
                set -l decoded_hdr_capacity_min (awk '/^--hdrCapacityMin / { print $2; exit }' "$gain_map_config_file")
                set -l decoded_hdr_capacity_max (awk '/^--hdrCapacityMax / { print $2; exit }' "$gain_map_config_file")

                if test -n "$decoded_max_content_boost"; and test -n "$decoded_hdr_capacity_max"
                    echo
                    echo "== ISO gain map 判断 =="
                    set -l iso_numeric_check (awk \
                        -v min_boost="$decoded_min_content_boost" \
                        -v max_boost="$decoded_max_content_boost" \
                        -v capacity_min="$decoded_hdr_capacity_min" \
                        -v capacity_max="$decoded_hdr_capacity_max" \
                        'BEGIN {
                            if (min_boost > 1.001) {
                                print "WARN: minContentBoost 大于 1，普通 HDR 显示器可能较晚触发增益"
                            } else {
                                print "OK: minContentBoost 不大于 1"
                            }

                            if (capacity_min < 1) {
                                print "BAD: hdrCapacityMin 小于 1"
                            } else {
                                print "OK: hdrCapacityMin 不小于 1"
                            }

                            if (capacity_max <= capacity_min) {
                                print "BAD: hdrCapacityMax 不大于 hdrCapacityMin"
                            } else {
                                print "OK: hdrCapacityMax 大于 hdrCapacityMin"
                            }

                            if (capacity_max > max_boost * 1.001) {
                                print "WARN: hdrCapacityMax 大于 maxContentBoost，Chrome/Skia 可能按 ISO 元数据减弱 HDR"
                            } else {
                                print "OK: hdrCapacityMax 与 maxContentBoost 对齐"
                            }
                        }')

                    printf "%s\n" $iso_numeric_check
                end
            else
                echo "ultrahdr_app 解码成功，但未输出 gain map 配置"
            end
            echo
            echo "OK: ultrahdr_app 可解码此 Ultra HDR JPEG"
        else
            echo "BAD: ultrahdr_app 无法解码此文件为 Ultra HDR JPEG"
        end
    else
        echo "提示: 安装 libultrahdr 后可用 ultrahdr_app 验证: brew install libultrahdr"
    end

    rm -rf "$temp_directory"
else
    echo "WARN: 无法创建临时目录，跳过 MPF/ultrahdr_app 检查"
end
