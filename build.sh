#!/usr/bin/env bash

# Linux amd64
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-w -s" -o ./build/ncmdump_linux_amd64 github.com/taurusxin/ncmdump-go

# macOS amd64
CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -ldflags="-w -s" -o ./build/ncmdump_darwin_amd64 github.com/taurusxin/ncmdump-go

# macOS arm64
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags="-w -s" -o ./build/ncmdump_darwin_arm64 github.com/taurusxin/ncmdump-go

# Windows amd64
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -ldflags="-w -s" -o ./build/ncmdump_windows_amd64.exe github.com/taurusxin/ncmdump-go