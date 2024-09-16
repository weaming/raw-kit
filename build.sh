#!/usr/bin/env bash

VERSION=1.5.0

# Clean up the build directory
rm -rf build
mkdir build

# Linux amd64
echo "Building for Linux amd64..."
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-w -s" -o build/ncmdump github.com/taurusxin/ncmdump-go
tar zcf build/ncmdump_linux_amd64_$VERSION.tar.gz -C build ncmdump
rm build/ncmdump

# Linux arm64
echo "Building for Linux arm64..."
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-w -s" -o build/ncmdump github.com/taurusxin/ncmdump-go
tar zcf build/ncmdump_linux_arm64_$VERSION.tar.gz -C build ncmdump
rm build/ncmdump

# macOS amd64
echo "Building for macOS amd64..."
CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -ldflags="-w -s" -o build/ncmdump github.com/taurusxin/ncmdump-go
tar zcf build/ncmdump_darwin_amd64_$VERSION.tar.gz -C build ncmdump
rm build/ncmdump

# macOS arm64
echo "Building for macOS arm64..."
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags="-w -s" -o build/ncmdump github.com/taurusxin/ncmdump-go
tar zcf build/ncmdump_darwin_arm64_$VERSION.tar.gz -C build ncmdump
rm build/ncmdump

# Windows amd64
echo "Building for Windows amd64..."
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -ldflags="-w -s" -o build/ncmdump.exe github.com/taurusxin/ncmdump-go
zip -q -j build/ncmdump_windows_amd64_$VERSION.zip ./build/ncmdump.exe
rm build/ncmdump.exe