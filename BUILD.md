# RawKit 构建说明

## 构建脚本

```bash
./build-release.fish
```

**功能：**
- 清理之前的构建
- 使用 Archive 方式构建 Release 版本
- 自动导出应用程序
- 生成 .dSYM 调试符号文件（用于崩溃分析）
- 显示详细的构建信息
- 输出应用的版本号、构建号和大小

**输出位置：**
- 应用: `build/Release/RawKit.app`
- Archive: `build/Release/RawKit.xcarchive`

**适用场景：** 正式发布、需要崩溃分析

---

## 版本信息

应用版本信息在 `RawKit.xcodeproj` 中配置：
- **Version**：CFBundleShortVersionString
- **Build**：CFBundleVersion

修改版本号后重新构建即可。

---

## 清理构建

如需完全清理：

```bash
rm -rf build/
rm -rf ~/Library/Developer/Xcode/DerivedData/RawKit-*
```

---

## 常见问题

### Q: 构建失败怎么办？

1. 确保 Xcode 命令行工具已安装：
   ```bash
   xcode-select --install
   ```

2. 清理后重试：
   ```bash
   xcodebuild clean -scheme RawKit -configuration Release
   ./build-release.fish
   ```

### Q: 应用无法打开？

macOS 可能会阻止未签名的应用。解决方法：
```bash
xattr -cr /Applications/RawKit.app
```

或在"系统偏好设置" → "安全性与隐私"中允许打开。

### Q: 如何创建正式的发布版本？

对于正式发布，建议：
1. 配置开发者证书和 Team ID
2. 启用公证（Notarization）
3. 使用 `xcodebuild` 的 exportArchive 选项

---

## 技术说明

- **构建配置：** Release
- **代码签名：** 自动签名（本地使用）
- **架构：** arm64（Apple Silicon）
- **最低系统：** macOS 13.0+
