# ProxySentry

ProxySentry 是一个 macOS 菜单栏诊断工具，用分层证据区分基础网络、系统代理、Clash 内核和当前节点的问题。它只做只读检测，不修改 Clash 配置，也不切换节点。

> 当前是未签名预览版（unsigned preview）。它适合试用、反馈和协作开发，不是 Clash Verge Rev 官方产品。

## 功能

面板中的四项指标含义如下：

| 指标 | 含义 |
| --- | --- |
| `base` | 基础网络：网卡、默认网关、直连公网地址和直连网站的综合证据。 |
| `traffic` | 代理流量：是否观察到 Clash 正在承载非直连连接；`WAIT` 表示暂时没有证据，不等于失败。 |
| `proxy` | 当前代理节点：通过本机代理对固定目标进行连通性和延迟检测。 |
| `clash` | Clash 内核：只读检查本机 Clash Verge Rev 的 Mihomo socket、版本、配置和连接汇总。 |

## 支持范围

- macOS 13 或更高版本。
- Apple 芯片和 Intel 芯片（通用二进制）。
- Clash Verge Rev；其他 Clash 客户端和自定义 socket 路径暂未承诺兼容。

ProxySentry 与 Clash Verge Rev、Mihomo、Apple、百度、Google、Cloudflare 或阿里云均无官方关联、背书或合作关系。

## 下载与安装

从 [Releases](https://github.com/justinjia0813/ProxySentry/releases) 下载带有 `macOS-universal-unsigned` 的 ZIP，解压后将 `ProxySentry.app` 移到“应用程序”文件夹。

这是未签名预览版，首次打开可能被 macOS 拦截：右键应用选择“打开”，然后在“系统设置 → 隐私与安全性”中选择“仍要打开”。也可参考 [Apple 官方的未签名应用打开说明](https://support.apple.com/guide/mac-help/mh40616/mac)。只从你信任的 Release 下载，发布页同时提供 Secure Hash Algorithm 256-bit（SHA-256，256 位安全散列算法）校验文件。

## 隐私说明

每轮诊断会发起少量只读网络探测：

- Apple 中国站 `www.apple.com.cn`、百度 `www.baidu.com`；
- Google `www.gstatic.com`、Cloudflare `cp.cloudflare.com`；
- Cloudflare 公网地址 `1.1.1.1:443` 和阿里云公共 Domain Name System（DNS，域名系统）地址 `223.5.5.5:443`。

应用只读访问本机 Clash Verge Rev 的固定 Unix socket，并读取白名单接口的聚合结果。它不会切换节点、修改配置或写入 Clash；不会上传或持久化原始连接、节点名称、订阅 Uniform Resource Locator（URL，统一资源定位符，即网络资源地址）、secret（访问密钥）或原始响应。检测结果只用于当前面板和本地诊断摘要。

应用运行期间会周期性检查网络；稳定状态下约每 60 秒一轮，用户也可以手动重查。DNS 会把域名解析为网络地址。

网络探测可能被本地网络、DNS、代理规则或目标站点策略阻断；失败结果应结合面板中的其他证据理解。

## 已知限制

- 仅支持 macOS；没有 Windows 或 Linux 版本。
- 需要 Clash Verge Rev 正在运行且其本地 socket 位于应用支持的固定路径。
- 未签名应用会触发 macOS 安全提示；当前没有自动更新器。
- 网络检测是瞬时采样，不保证代表所有应用或所有网站的实际体验。

## 从源码构建

需要安装 Xcode 和 macOS 开发工具：

```sh
xcodebuild -project ProxySentry.xcodeproj -scheme ProxySentry -configuration Debug \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

生成未签名通用 Release 包：

```sh
./scripts/package-release.sh 0.1.0
```

脚本会检查生成应用的 arm64、x86_64 架构以及 macOS 13.0 最低版本，并在 `dist/` 生成 ZIP 与 SHA-256 文件。

## 参与贡献

欢迎提交 Issue 和 Pull Request：先描述可复现的问题或改进目标，再提交尽量小的改动。提交前请运行相关测试和 `git diff --check`。不要把 Clash secret、订阅 URL、原始连接日志或个人信息提交到仓库；详见 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [SECURITY.md](SECURITY.md)。

## 许可证

本项目使用 [Massachusetts Institute of Technology License（MIT License，麻省理工学院许可证，一种允许使用、修改和再分发的宽松开源许可证）](LICENSE)。
