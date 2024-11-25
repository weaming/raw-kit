#!/usr/bin/env bash

VERSION=1.7.1

# Clean up the build directory
rm -rf build
mkdir build

# Linux amd64
echo "Building for Linux amd64..."
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-w -s" -o build/ncmdump-go git.taurusxin.com/taurusxin/ncmdump-go
tar zcf build/ncmdump-go_linux_amd64_$VERSION.tar.gz -C build ncmdump-go
rm build/ncmdump-go

# Linux arm64
echo "Building for Linux arm64..."
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-w -s" -o build/ncmdump-go git.taurusxin.com/taurusxin/ncmdump-go
tar zcf build/ncmdump-go_linux_arm64_$VERSION.tar.gz -C build ncmdump-go
rm build/ncmdump-go

# macOS amd64
echo "Building for macOS amd64..."
CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -ldflags="-w -s" -o build/ncmdump-go git.taurusxin.com/taurusxin/ncmdump-go
tar zcf build/ncmdump-go_darwin_amd64_$VERSION.tar.gz -C build ncmdump-go
rm build/ncmdump-go

# macOS arm64
echo "Building for macOS arm64..."
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags="-w -s" -o build/ncmdump-go git.taurusxin.com/taurusxin/ncmdump-go
tar zcf build/ncmdump-go_darwin_arm64_$VERSION.tar.gz -C build ncmdump-go
rm build/ncmdump-go

# Windows amd64
echo "Building for Windows amd64..."
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -ldflags="-w -s" -o build/ncmdump-go.exe git.taurusxin.com/taurusxin/ncmdump-go
zip -q -j build/ncmdump-go_windows_amd64_$VERSION.zip ./build/ncmdump-go.exe
rm build/ncmdump-go.exe