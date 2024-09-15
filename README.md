# ncmdump-go

基于 https://github.com/taurusxin/ncmdump 的 Golang 移植版

支持网易云音乐最新的 3.x 版本

## 使用方法

```shell
# 处理单个或多个文件
ncmdump test1.ncm test2.ncm...

# 处理 Music 文件夹下的所有文件
ncmdump -d Music
```

注意：网易云音乐从 3.0 版本开始不再在 ncm 文件中嵌入封面图片，本工具支持从网易服务器上自动下载对应歌曲的封面图并写入到最终的音乐文件中

## 开发

使用 go module 下载 ncmdump-go 包

```shell
go get -u github.com/taurusxin/ncmdump-go
```

导入并使用

```go
package main

import (
	"fmt"
	"github.com/taurusxin/ncmdump-go/ncmcrypt"
)

func main() {
	filePath := "test.ncm"
	
	// 创建实例
	ncm, err := ncmcrypt.NewNeteaseCloudMusic(filePath)
	if err != nil {
		fmt.Printf("Reading '%s' failed: '%s'\n", filePath, err.Error())
		return
	}
	
	// 转换格式，若目标文件夹为空，则保存在原目录
	dumpResult, err := ncm.Dump("")
	if err != nil {
		fmt.Printf("Processing '%s' failed: '%s'\n", filePath, err.Error())
	}
	if dumpResult {
		// 使用源文件的元数据修补转换后的音乐文件
		// 注意：自网易云音乐 3.0 版本开始，ncm 文件中不再内嵌专辑封面图片，参数若为 true 则表示从网易服务器上下载图片并嵌入到目标音乐文件（需要联网）
		metadata, err := ncm.FixMetadata(true)
		if !metadata {
			fmt.Printf("Fix metadata for '%s' failed: '%s'", filePath, err.Error())
		}
		fmt.Printf("'%s' -> '%s'\n", filePath, ncm.GetDumpFilePath())
	}
}
```

