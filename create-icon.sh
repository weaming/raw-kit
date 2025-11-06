#!/bin/bash

# RawKit 图标生成脚本
# 用法: ./create-icon.sh path/to/your-icon.png

if [ "$#" -ne 1 ]; then
    echo "用法: $0 <图标文件路径>"
    echo "图标应该是 1024x1024 的 PNG 文件"
    exit 1
fi

INPUT_IMAGE="$1"

if [ ! -f "$INPUT_IMAGE" ]; then
    echo "错误: 找不到文件 $INPUT_IMAGE"
    exit 1
fi

ICONSET_DIR="AppIcon.iconset"

echo "创建 iconset 目录..."
mkdir -p "$ICONSET_DIR"

echo "生成各种尺寸的图标..."
sips -z 16 16     "$INPUT_IMAGE" --out "$ICONSET_DIR/icon_16x16.png"
sips -z 32 32     "$INPUT_IMAGE" --out "$ICONSET_DIR/icon_16x16@2x.png"
sips -z 32 32     "$INPUT_IMAGE" --out "$ICONSET_DIR/icon_32x32.png"
sips -z 64 64     "$INPUT_IMAGE" --out "$ICONSET_DIR/icon_32x32@2x.png"
sips -z 128 128   "$INPUT_IMAGE" --out "$ICONSET_DIR/icon_128x128.png"
sips -z 256 256   "$INPUT_IMAGE" --out "$ICONSET_DIR/icon_128x128@2x.png"
sips -z 256 256   "$INPUT_IMAGE" --out "$ICONSET_DIR/icon_256x256.png"
sips -z 512 512   "$INPUT_IMAGE" --out "$ICONSET_DIR/icon_256x256@2x.png"
sips -z 512 512   "$INPUT_IMAGE" --out "$ICONSET_DIR/icon_512x512.png"
sips -z 1024 1024 "$INPUT_IMAGE" --out "$ICONSET_DIR/icon_512x512@2x.png"

echo "转换为 .icns 文件..."
iconutil -c icns "$ICONSET_DIR"

echo "清理临时文件..."
rm -rf "$ICONSET_DIR"

echo "✓ 图标生成成功: AppIcon.icns"
echo "请将此文件添加到 RawKit/Assets.xcassets/AppIcon"
