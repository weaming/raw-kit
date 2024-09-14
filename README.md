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