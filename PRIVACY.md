# 隐私 / Privacy

Ez Audio Control 的应用代码没有遥测、账户、广告 SDK、联网激活或自动更新请求。

## 本机处理

- 原生设备音量通过 CoreAudio 读取/写入；点击设备时才请求切换默认输出。
- 软件模式处理当前输出的系统音频，在内存中衰减后回送。它使用 macOS 系统音频捕获许可，不读取物理麦克风，不把音频写入文件。
- 音量键接管依赖你授予的系统控制许可，只处理音量指令，不记录普通键盘内容。
- 蓝牙入口使用系统已配对设备信息；明确点选后才请求许可、连接或切换，不主动扫描或配对新设备。
- 偏好保存在应用的 UserDefaults 中。登录项只在你点选时修改。
- 自身事务和故障写入本机有界日志：`~/Library/Logs/SimpleAudioControl/audio-transactions.log`。日志可能包含设备标识、状态及时间；请勿公开上传整份日志。
- “复制支持信息”仅写入剪贴板，不发送。请在分享前阅读其内容。

系统设置入口由你点击打开。赞助功能默认未配置、隐藏；若维护者自行配置，只有点击网站才使用默认浏览器打开，后续数据处理由目标网站负责。本仓库不含收款码或个人支付配置。

## English

The App code contains no telemetry, accounts, advertising SDK, network activation or automatic-update requests. Audio attenuation stays in memory; no physical microphone is opened and no audio is saved. Only volume commands are handled, not ordinary typing.

Preferences and bounded diagnostic logs stay on this Mac. Logs can contain device identifiers, state and timing; do not post complete logs publicly. Copy Support Info only writes to the clipboard. Output selection, Bluetooth connection, login changes and opening settings occur through explicit user actions. System audio capture and volume-command handling are subject to macOS permissions.

Sponsorship is unconfigured and hidden in this source tree. A configured external website is opened only after a click; its privacy practices are separate.
