# Contributing / 参与开发

先阅读 [README](README.md) 和 [架构](Docs/ARCHITECTURE.md)。当前发布版本为 1.0.0；请用小范围改动解决明确问题，不把音量工具扩展为驱动安装器或音频录制器。

## 本地验证

```sh
./scripts/build.sh --adhoc
./scripts/test-offline.sh
```

离线测试使用假 CoreAudio/蓝牙设备、合成缓冲和离屏控件，不创建真实音频链路、不调整音量、不发系统音量事件。它们不能证明真实设备、听感或跨夜唤醒通过。

需要真实测试时，请先暂停其它播放并降低外部音箱硬件音量。权限由用户处理；不要在测试脚本中安装驱动、修改 TCC、重启音频服务、自动换输出或播放测试声音。

## 提交内容

- 说明具体问题、修改后的行为及实际验证结果。
- 修改界面文字时同步 `en` 与 `zh-Hans`，检查真实尺寸和换行。
- 保留版权与第三方许可。不要提交证书、签名配置、密钥、付款配置、运行日志、个人路径或构建包。
- 不要求贡献者交出签名身份或音频权限。发布由维护者按 [发布清单](Docs/RELEASING.md) 单独处理。

By submitting original changes for inclusion, you agree to license those contributions under this project's MIT license. Keep upstream attribution, describe the resulting behavior and distinguish offline tests from hardware validation.
