#!/usr/bin/env fish

# RawKit Release 构建脚本
# 使用方法: ./build-release.fish

set -l PROJECT_DIR (pwd)
set -l APP_NAME "RawKit"
set -l SCHEME "RawKit"
set -l OUTPUT_DIR "$PROJECT_DIR/build/Release"

echo "🚀 开始构建 $APP_NAME Release 版本..."
echo "📁 项目目录: $PROJECT_DIR"
echo ""

# 清理之前的构建
echo "🧹 清理之前的构建..."
if test -d "$OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR"
end
mkdir -p "$OUTPUT_DIR"

# 清理 Xcode DerivedData
echo "🧹 清理 DerivedData..."
xcodebuild clean -scheme $SCHEME -configuration Release 2>&1 | grep -E "CLEAN (SUCCEEDED|FAILED)|error:" || true

echo ""
echo "🔨 开始编译 Release 版本..."
echo "⏳ 这可能需要几分钟时间..."
echo ""

# 构建 Release 版本
xcodebuild \
    -scheme $SCHEME \
    -configuration Release \
    -derivedDataPath "$PROJECT_DIR/build/DerivedData" \
    -archivePath "$OUTPUT_DIR/$APP_NAME.xcarchive" \
    archive \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="" \
    2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:|warning:|note:" || true

if test $status -ne 0
    echo ""
    echo "❌ 构建失败！"
    exit 1
end

# 检查 archive 是否成功
if not test -d "$OUTPUT_DIR/$APP_NAME.xcarchive"
    echo ""
    echo "❌ Archive 失败！未找到 .xcarchive 文件"
    exit 1
end

# 导出 app
echo ""
echo "📦 导出应用程序..."

# 从 archive 中提取 app
set -l APP_PATH "$OUTPUT_DIR/$APP_NAME.xcarchive/Products/Applications/$APP_NAME.app"
if test -d "$APP_PATH"
    cp -R "$APP_PATH" "$OUTPUT_DIR/"
    echo "✅ 应用已导出到: $OUTPUT_DIR/$APP_NAME.app"
else
    echo "❌ 未找到应用程序文件"
    exit 1
end

# 获取应用信息
if test -d "$OUTPUT_DIR/$APP_NAME.app"
    echo ""
    echo "📋 应用信息:"
    set -l VERSION (defaults read "$OUTPUT_DIR/$APP_NAME.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "未知")
    set -l BUILD (defaults read "$OUTPUT_DIR/$APP_NAME.app/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo "未知")
    set -l SIZE (du -sh "$OUTPUT_DIR/$APP_NAME.app" | awk '{print $1}')

    echo "   版本: $VERSION"
    echo "   构建: $BUILD"
    echo "   大小: $SIZE"
end

echo ""
echo "✅ 构建完成！"
echo ""
echo "📍 应用位置:"
echo "   $OUTPUT_DIR/$APP_NAME.app"
echo ""
echo "💡 使用方法:"
echo "   1. 打开 Finder 进入上述目录"
echo "   2. 将 $APP_NAME.app 拖到 /Applications 文件夹"
echo "   3. 或者运行: cp -R '$OUTPUT_DIR/$APP_NAME.app' /Applications/"
echo ""
echo "🎉 完成！"

open ./build/Release/