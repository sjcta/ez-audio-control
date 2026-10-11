# Release checklist / 发布清单

源码开放、可构建、正式二进制发行和硬件验收分别记录。当前仓库是开发预览源码，未提供已公证的正式发行包。

1. 确认本次源码版本、原始改动版权与素材权利；保留根 LICENSE 和两份上游 MIT 许可。
2. 用公开目录构建，运行离线测试；确认所有资源、翻译及许可随 App 打包。
3. 扫描待发布内容：无证书/私钥、签名配置、支付配置、日志、个人路径或内部 Git 历史。
4. 用维护者已有 Developer ID、Hardened Runtime、安全时间戳及最小必要 entitlement 签名。签名不等于公证或功能通过。
5. 测试最终 App 本身；由用户确认当前版本可用后再制作新的 DMG/ZIP。App、权限提示、输入设备、音频路径及睡眠唤醒分别记录实际结果。
6. Apple 公证上传须由维护者明确决定；成功后附加票据，并测试实际带下载隔离标记的安装流程。不要把未公证构建标为正式发行包。
7. 发行说明列明已验证的系统/设备、已知问题、安装/卸载方法及回滚前提。跨夜测试未完成时明确标注。

CI deliberately has no signing secrets, distribution upload or automatic release job. Its local-build success is not evidence of notarization, Gatekeeper acceptance or hardware compatibility.

Runner configuration currently uses GitHub's documented [`xcode-27` preview image](https://github.com/actions/runner-images#available-images) because the source references macOS 27 SDK properties. Cloud execution has not been verified until the workflow actually runs; monitor image availability before release.
