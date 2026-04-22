#!/usr/bin/env fish

function usage
    echo "Package an existing RawKit.app for distribution."
    echo ""
    echo "Usage:"
    echo "  ./pkg.fish"
    echo "  ./pkg.fish --app-path /path/to/RawKit.app"
    echo "  ./pkg.fish --with-dsym"
    echo "  ./pkg.fish --name RawKit-custom"
    echo ""
    echo "Options:"
    echo "  --app-path <path>     App bundle to package"
    echo "  --output-dir <dir>    Output directory for archives"
    echo "  --archive-path <dir>  .xcarchive directory used to find dSYM"
    echo "  --dsym-path <path>    Explicit dSYM bundle path"
    echo "  --name <basename>     Override output basename (without .zip)"
    echo "  --with-dsym           Also package RawKit.app.dSYM separately"
    echo "  --skip-verify         Skip codesign verification"
    echo "  -h, --help            Show this help"
end

function read_plist_value --argument-names plist_path key fallback
    set -l value (defaults read "$plist_path" "$key" 2>/dev/null)
    if test $status -eq 0
        echo $value
    else
        echo $fallback
    end
end

function package_zip --argument-names source_path zip_path
    rm -f "$zip_path" "$zip_path.sha256"

    ditto -c -k --keepParent "$source_path" "$zip_path"
    or return 1

    if not test -f "$zip_path"
        echo "error: failed to create $zip_path" >&2
        return 1
    end

    shasum -a 256 "$zip_path" > "$zip_path.sha256"
    or return 1
end

set -l SCRIPT_PATH (status filename)
set -l PROJECT_DIR (cd (dirname "$SCRIPT_PATH"); and pwd)
set -l APP_NAME "RawKit"
set -l APP_PATH "$PROJECT_DIR/build/Release/$APP_NAME.app"
set -l OUTPUT_DIR "$PROJECT_DIR/build/Release"
set -l ARCHIVE_PATH "$PROJECT_DIR/build/Release/$APP_NAME.xcarchive"
set -l DSYM_PATH ""
set -l INCLUDE_DSYM 0
set -l VERIFY_APP 1
set -l CUSTOM_NAME ""

set -l i 1
while test $i -le (count $argv)
    set -l arg $argv[$i]

    switch $arg
    case --app-path --output-dir --archive-path --dsym-path --name
        set i (math "$i + 1")
        if test $i -gt (count $argv)
            echo "error: missing value for $arg" >&2
            usage
            exit 2
        end

        switch $arg
        case --app-path
            set APP_PATH $argv[$i]
        case --output-dir
            set OUTPUT_DIR $argv[$i]
        case --archive-path
            set ARCHIVE_PATH $argv[$i]
        case --dsym-path
            set DSYM_PATH $argv[$i]
        case --name
            set CUSTOM_NAME $argv[$i]
        end
    case --with-dsym
        set INCLUDE_DSYM 1
    case --skip-verify
        set VERIFY_APP 0
    case -h --help
        usage
        exit 0
    case '*'
        echo "error: unknown argument $arg" >&2
        usage
        exit 2
    end

    set i (math "$i + 1")
end

if not test -d "$APP_PATH"
    echo "error: app bundle not found: $APP_PATH" >&2
    echo "hint: run ./build-release.fish first, or pass --app-path" >&2
    exit 1
end

set -l INFO_PLIST "$APP_PATH/Contents/Info.plist"
if not test -f "$INFO_PLIST"
    echo "error: missing Info.plist inside app bundle: $INFO_PLIST" >&2
    exit 1
end

mkdir -p "$OUTPUT_DIR"
or exit 1

if test $VERIFY_APP -eq 1
    echo "Verifying codesign..."
    codesign --verify --deep --strict "$APP_PATH"
    or begin
        echo "error: codesign verification failed for $APP_PATH" >&2
        exit 1
    end
end

set -l VERSION (read_plist_value "$INFO_PLIST" CFBundleShortVersionString "unknown")
set -l BASENAME "$APP_NAME-$VERSION-macOS"
if test -n "$CUSTOM_NAME"
    set BASENAME "$CUSTOM_NAME"
end

set -l APP_ZIP_PATH "$OUTPUT_DIR/$BASENAME.zip"

echo "Packaging app:"
echo "  source: $APP_PATH"
echo "  output: $APP_ZIP_PATH"

package_zip "$APP_PATH" "$APP_ZIP_PATH"
or exit 1

set -l APP_SIZE (du -sh "$APP_ZIP_PATH" | awk '{print $1}')
echo "  size:   $APP_SIZE"
echo "  sha256: $APP_ZIP_PATH.sha256"

if test $INCLUDE_DSYM -eq 1
    if test -z "$DSYM_PATH"
        set DSYM_PATH "$ARCHIVE_PATH/dSYMs/$APP_NAME.app.dSYM"
    end

    if not test -d "$DSYM_PATH"
        echo "error: dSYM bundle not found: $DSYM_PATH" >&2
        exit 1
    end

    set -l DSYM_ZIP_PATH "$OUTPUT_DIR/$BASENAME-dSYM.zip"

    echo ""
    echo "Packaging dSYM:"
    echo "  source: $DSYM_PATH"
    echo "  output: $DSYM_ZIP_PATH"

    package_zip "$DSYM_PATH" "$DSYM_ZIP_PATH"
    or exit 1

    set -l DSYM_SIZE (du -sh "$DSYM_ZIP_PATH" | awk '{print $1}')
    echo "  size:   $DSYM_SIZE"
    echo "  sha256: $DSYM_ZIP_PATH.sha256"
end

echo ""
echo "Done."
