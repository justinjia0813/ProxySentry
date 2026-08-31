# ProxySentry

ProxySentry 是一个 macOS 网络诊断工具，用分层证据区分基础网络、系统代理、Clash 内核和当前节点的问题。当前本地源码已实现 2.0：状态面板收纳到刘海区域，并以终端风格胶囊按需展开。它只做只读检测，不修改 Clash 配置，也不切换节点。

2.0 尚未发布。本 README 描述的是当前本地实现，不代表已有 2.0 下载包或远程发布结果；公开下载仍是 v0.1.0 菜单栏版本。

> 当前是未签名预览版（unsigned preview）。它适合试用、反馈和协作开发，不是 Clash Verge Rev 官方产品。

## 已发布版本（v0.1.0）

公开的 v0.1.0 常驻菜单栏，点击状态图标打开诊断面板；2.0 本地源码已改为刘海浮窗。两者都使用四行诊断矩阵：

面板中的四项指标含义如下：

| 指标 | 含义 |
| --- | --- |
| `base` | 基础网络：网卡、默认网关、直连公网地址和直连网站的综合证据。 |
| `traffic` | 代理流量：是否观察到 Clash 正在承载非直连连接；`WAIT` 表示暂时没有证据，不等于失败。 |
| `proxy` | 当前代理节点：通过本机代理对固定目标进行连通性和延迟检测。 |
| `clash` | Clash 内核：只读检查本机 Clash Verge Rev 的 Mihomo socket、版本、配置和连接汇总。 |

## 2.0 本地实现（未发布）

- 不显示菜单栏或 Dock 图标；状态收纳在刘海区域，悬停时展开终端风格胶囊。
- 网络或系统代理变化只触发后台复检，不自动展开；黄、红或灰状态连续至少 3 分钟时短暂展开一次，恢复正常后才允许下一次提醒。
- 鼠标离开、外部点击或 Escape 后收起；收起不停止诊断。
- 有刘海的屏幕使用刘海左右可用区域；无刘海外接屏或普通屏幕退化为顶部胶囊。
- 适配多屏、全屏 Space、浅色/深色模式、长文本、VoiceOver 和低占用后台运行。
- 只使用公开 AppKit API（Application Programming Interface，应用程序编程接口；系统允许应用调用的接口），不使用 SkyLight、Core Graphics Services（CGS，核心图形服务；macOS 私有窗口管理接口）或其他私有 API，也不申请辅助功能权限。

## 支持范围

- macOS 13 或更高版本。
- Apple 芯片和 Intel 芯片（通用二进制）。
- Clash Verge Rev；其他 Clash 客户端和自定义 socket 路径暂未承诺兼容。

ProxySentry 与 Clash Verge Rev、Mihomo、Apple、百度、Google、Cloudflare 或阿里云均无官方关联、背书或合作关系。

## 获取本地构建

当前没有授权的 2.0 发布包。若需要试用当前本地源码，请自行构建；签名、公证和公开发布仍未授权。

本地构建产物为未签名预览版，首次打开可能被 macOS 拦截：右键应用选择“打开”，然后在“系统设置 → 隐私与安全性”中选择“仍要打开”。也可参考 [Apple 官方的未签名应用打开说明](https://support.apple.com/guide/mac-help/mh40616/mac)。

## 隐私说明

每轮诊断会发起少量只读网络探测：

- Apple 中国站 `www.apple.com.cn`、百度 `www.baidu.com`；
- Google `www.gstatic.com`、Cloudflare `cp.cloudflare.com`；
- Cloudflare 公网地址 `1.1.1.1:443` 和阿里云公共 Domain Name System（DNS，域名系统）地址 `223.5.5.5:443`。

应用只读访问本机 Clash Verge Rev 的固定 Unix socket，并读取白名单接口的聚合结果。它不会切换节点、修改配置或写入 Clash；不会上传或持久化原始连接、节点名称、订阅 Uniform Resource Locator（URL，统一资源定位符，即网络资源地址）、secret（访问密钥）或原始响应。检测结果只用于当前面板和本地诊断摘要。

应用运行期间会周期性检查网络；当前本地实现约每 60 秒一轮，用户也可以手动重查。网络变化会立即触发后台复检但不展开；黄、红或灰状态连续至少 3 分钟时，面板短暂展开一次。DNS 会把域名解析为网络地址。

网络探测可能被本地网络、DNS、代理规则或目标站点策略阻断；失败结果应结合面板中的其他证据理解。

## 已知限制

- 仅支持 macOS；没有 Windows 或 Linux 版本。
- 需要 Clash Verge Rev 正在运行且其本地 socket 位于应用支持的固定路径。
- 未签名应用会触发 macOS 安全提示；当前没有自动更新器。2.0 尚未发布，也没有签名、公证或公开发布承诺。
- 网络检测是瞬时采样，不保证代表所有应用或所有网站的实际体验。

## 从源码构建

需要安装 Xcode 和 macOS 开发工具：

```sh
xcodebuild -project ProxySentry.xcodeproj -scheme ProxySentry -configuration Debug \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

生成未签名通用本地 Release 包（不代表已发布）：

```sh
./scripts/package-release.sh 2.0.0
```

脚本会检查生成应用的 arm64、x86_64 架构以及 macOS 13.0 最低版本，并在 `dist/` 生成 ZIP 与 Secure Hash Algorithm 256-bit（SHA-256，256 位安全散列算法；用于核对文件是否被改动）文件。

## 参与贡献

欢迎提交 Issue 和 Pull Request：先描述可复现的问题或改进目标，再提交尽量小的改动。提交前请运行相关测试和 `git diff --check`。不要把 Clash secret、订阅 URL、原始连接日志或个人信息提交到仓库；详见 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [SECURITY.md](SECURITY.md)。

## 许可证

本项目使用 [Massachusetts Institute of Technology License（MIT License，麻省理工学院许可证，一种允许使用、修改和再分发的宽松开源许可证）](LICENSE)。
