#!/usr/bin/env fish

# RawKit 图标生成脚本
# 用法: ./create-icon.sh [图标文件路径]
# 如果不指定路径，默认使用 icon-1024.png

set INPUT_IMAGE icon-1024.png

if test (count $argv) -eq 1
    set INPUT_IMAGE $argv[1]
end

if not test -f $INPUT_IMAGE
    echo "错误: 找不到文件 $INPUT_IMAGE"
    exit 1
end

set ICONSET_DIR AppIcon.iconset
set ASSETS_DIR RawKit/Assets.xcassets/AppIcon.appiconset

echo "🎨 开始生成图标..."
echo "📁 源文件: $INPUT_IMAGE"

echo "📦 创建临时目录..."
mkdir -p $ICONSET_DIR

echo "🖼️  生成各种尺寸的图标..."
sips -z 16 16 $INPUT_IMAGE --out $ICONSET_DIR/icon_16x16.png > /dev/null
sips -z 32 32 $INPUT_IMAGE --out $ICONSET_DIR/icon_16x16@2x.png > /dev/null
sips -z 32 32 $INPUT_IMAGE --out $ICONSET_DIR/icon_32x32.png > /dev/null
sips -z 64 64 $INPUT_IMAGE --out $ICONSET_DIR/icon_32x32@2x.png > /dev/null
sips -z 128 128 $INPUT_IMAGE --out $ICONSET_DIR/icon_128x128.png > /dev/null
sips -z 256 256 $INPUT_IMAGE --out $ICONSET_DIR/icon_128x128@2x.png > /dev/null
sips -z 256 256 $INPUT_IMAGE --out $ICONSET_DIR/icon_256x256.png > /dev/null
sips -z 512 512 $INPUT_IMAGE --out $ICONSET_DIR/icon_256x256@2x.png > /dev/null
sips -z 512 512 $INPUT_IMAGE --out $ICONSET_DIR/icon_512x512.png > /dev/null
sips -z 1024 1024 $INPUT_IMAGE --out $ICONSET_DIR/icon_512x512@2x.png > /dev/null

echo "📋 复制图标到 Assets..."
cp $ICONSET_DIR/*.png $ASSETS_DIR/

echo "💾 生成 .icns 文件..."
iconutil -c icns $ICONSET_DIR

echo "🧹 清理临时文件..."
rm -rf $ICONSET_DIR
