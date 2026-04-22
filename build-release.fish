#!/usr/bin/env fish

# RawKit Release 构建脚本
# 使用方法:
#   ./build-release.fish
#   ./build-release.fish --no-clean
#   ./build-release.fish --verbose

set -l SCRIPT_PATH (status filename)
set -l PROJECT_DIR (cd (dirname "$SCRIPT_PATH"); and pwd)
set -l PROJECT_PATH "$PROJECT_DIR/RawKit.xcodeproj"
set -l APP_NAME "RawKit"
set -l SCHEME "RawKit"
set -l BUILD_DIR "$PROJECT_DIR/build"
set -l OUTPUT_DIR "$BUILD_DIR/Release"
set -l DERIVED_DATA_DIR "$BUILD_DIR/DerivedData"
set -l ARCHIVE_PATH "$OUTPUT_DIR/$APP_NAME.xcarchive"
set -l EXPORTED_APP_PATH "$OUTPUT_DIR/$APP_NAME.app"
set -l BUILD_LOG "$OUTPUT_DIR/build.log"
set -l CLEAN_BUILD 1
set -l VERBOSE 0

for arg in $argv
    switch $arg
    case --no-clean
        set CLEAN_BUILD 0
    case --verbose
        set VERBOSE 1
    case '*'
        echo "❌ 未知参数: $arg"
        echo "使用方法: ./build-release.fish [--no-clean] [--verbose]"
        exit 2
    end
end

if not test -d "$PROJECT_PATH"
    echo "❌ 未找到项目文件: $PROJECT_PATH"
    exit 1
end

set -l start_time (date +%s)

echo "🚀 开始构建 $APP_NAME Release 版本..."
echo "📁 项目目录: $PROJECT_DIR"
echo "📦 输出目录: $OUTPUT_DIR"
if test $CLEAN_BUILD -eq 1
    echo "🧹 构建模式: clean"
else
    echo "⚡ 构建模式: incremental (--no-clean)"
end
echo ""

mkdir -p "$OUTPUT_DIR"

echo "🧹 清理旧产物..."
rm -rf "$ARCHIVE_PATH" "$EXPORTED_APP_PATH" "$BUILD_LOG"

if test $CLEAN_BUILD -eq 1
    rm -rf "$OUTPUT_DIR" "$DERIVED_DATA_DIR"
    mkdir -p "$OUTPUT_DIR"
else
    mkdir -p "$DERIVED_DATA_DIR"
end

set -l xcodebuild_args
if test $VERBOSE -ne 1
    set xcodebuild_args $xcodebuild_args -quiet
end

echo "🔨 开始 Archive..."
echo ""

xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    -archivePath "$ARCHIVE_PATH" \
    -hideShellScriptEnvironment \
    $xcodebuild_args \
    archive \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="" \
    2>&1 | tee "$BUILD_LOG"

set -l build_status $pipestatus[1]
if test $build_status -ne 0
    echo ""
    echo "❌ 构建失败，xcodebuild exit code: $build_status"
    echo "🧾 构建日志: $BUILD_LOG"
    echo ""
    echo "最后 60 行日志:"
    tail -n 60 "$BUILD_LOG"
    exit $build_status
end

if not test -d "$ARCHIVE_PATH"
    echo ""
    echo "❌ Archive 失败：未找到 $ARCHIVE_PATH"
    exit 1
end

echo ""
echo "📦 导出应用程序..."

set -l APP_PATH_IN_ARCHIVE "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
if not test -d "$APP_PATH_IN_ARCHIVE"
    echo "❌ Archive 内未找到应用程序: $APP_PATH_IN_ARCHIVE"
    exit 1
end

ditto "$APP_PATH_IN_ARCHIVE" "$EXPORTED_APP_PATH"

if not test -d "$EXPORTED_APP_PATH"
    echo "❌ 导出失败：未生成 $EXPORTED_APP_PATH"
    exit 1
end

set -l VERSION (defaults read "$EXPORTED_APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null; or echo "未知")
set -l BUILD (defaults read "$EXPORTED_APP_PATH/Contents/Info.plist" CFBundleVersion 2>/dev/null; or echo "未知")
set -l SIZE (du -sh "$EXPORTED_APP_PATH" | awk '{print $1}')
set -l WARNINGS (rg -c "warning:" "$BUILD_LOG" 2>/dev/null; or echo "0")
set -l NOTES (rg -c "note:" "$BUILD_LOG" 2>/dev/null; or echo "0")
set -l DSYM_PATH "$ARCHIVE_PATH/dSYMs/$APP_NAME.app.dSYM"
set -l end_time (date +%s)
set -l elapsed_seconds (math "$end_time - $start_time")

echo ""
echo "📋 构建结果:"
echo "   版本: $VERSION"
echo "   构建: $BUILD"
echo "   大小: $SIZE"
echo "   耗时: $elapsed_seconds"s
echo "   Warning: $WARNINGS"
echo "   Note: $NOTES"
echo ""
echo "📍 输出文件:"
echo "   App: $EXPORTED_APP_PATH"
echo "   Archive: $ARCHIVE_PATH"
if test -d "$DSYM_PATH"
    echo "   dSYM: $DSYM_PATH"
end
echo "   日志: $BUILD_LOG"
echo ""
echo "✅ 构建完成"
