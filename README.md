# 爱悦 · 本地音乐播放器

Flutter 原生应用，参照提供的设计稿实现深色背景、荧光绿播放按钮、大封面和文件夹播放列表。手机为单列，桌面宽屏为双列。封面图片从用户提供的设计稿裁切，仅作为默认展示图。

## 运行

```sh
flutter pub get
flutter run -d macos
# 或在连接 Android 设备后：
flutter run -d android
```

macOS 需要完整 Xcode（仅 Command Line Tools 不够）和 CocoaPods。Windows/Linux 请在对应系统运行 Flutter，并安装该平台的 Flutter 桌面构建依赖。不提供 Web 版：本项目直接访问本地文件系统。

## 使用

扫描文件夹后会显示 MP3 勾选窗口，默认不选中歌曲。支持搜索、全选当前搜索结果和清空选择，确认后才更新播放列表；取消不改变现有列表。重启后只恢复上次勾选的歌曲。

点击“文件夹”或“导入音乐文件夹”，选择包含 MP3 的目录，递归扫描子目录；点击歌曲播放。支持拖动进度、上一首/下一首、随机、顺序/列表循环/单曲循环、0.75–2 倍速、15–60 分钟定时停止、文件名搜索和收藏。文件夹路径与收藏记录保存在本机，不上传音频。

macOS 已配置用户选择文件的只读权限。沙盒权限在重启后可能需要重新选择文件夹授权。Android 通过系统 Storage Access Framework 选择目录，保留读取授权，递归查询文档 URI 并直接播放 content URI，无需全盘访问权限；系统禁止选择的受保护目录无法导入。iOS 文件夹访问需要在实机验证，不承诺可遍历任意外部提供商目录。

## 验证

Android 构建已在项目 Gradle Wrapper 中关闭 configuration cache，以兼容 Flutter 3.35 的 `DebugMinSdkCheck`；即使全局 `~/.gradle/gradle.properties` 开启此缓存也不会影响本项目。普通构建缓存保持原设置。依赖的“newer versions incompatible”提示不是编译错误，无需为此强制升级依赖。

```sh
flutter analyze
flutter test
```

目前没有 ID3 标签/嵌入封面解析、歌词和后台媒体通知。时长从实际音频读取，不显示虚构码率与歌曲数据。
