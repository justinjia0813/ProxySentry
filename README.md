# ProxySentry

一眼判断“网络不好”到底坏在哪一层。

ProxySentry 是一款轻量的 macOS 网络诊断工具。它把基础网络、代理流量、当前节点和 Clash 内核拆成四层证据，并把结果收纳在刘海或屏幕顶部。诊断主进程只读；2.2 新增默认关闭、需明确启用的独立入口自愈辅助进程。

[下载 2.2 未签名预览版](https://github.com/justinjia0813/ProxySentry/releases/tag/preview-v2.2.1) · [查看全部版本](https://github.com/justinjia0813/ProxySentry/releases) · [报告问题](https://github.com/justinjia0813/ProxySentry/issues)

![ProxySentry 终端风格诊断面板（2.0 示意图）](docs/assets/proxysentry-2.0.png)

> [!IMPORTANT]
> GitHub 上提供的是 2.2.1 未签名预览包。它没有 Developer ID（Developer Identifier，开发者标识；Apple 用来识别独立开发者签名身份）签名，也没有通过 Apple 公证，macOS Gatekeeper 会拦截它。现阶段适合开发测试，不是面向普通用户的免提示安装包。

## 功能

- 不占用菜单栏或 Dock；有刘海时收进刘海区域，无刘海显示器退化为顶部居中胶囊。
- 鼠标移入时展开，离开、外部点击或按 Escape 后收起。
- 网络变化只在后台复检，不因短暂波动打断用户；异常连续至少 3 分钟才主动提示一次，恢复后才允许再次提醒。
- 使用终端风格的高对比界面，同时适配深色、浅色、多屏、全屏 Space、长文本和 VoiceOver。
- 只使用公开 AppKit 接口，不申请辅助功能权限，不使用 macOS 私有窗口接口。
- 基础网络失败时明确显示 `BASE FAILURE`，代理流量和节点检测标记为 `BLOCKED`，不把下游超时误判为机场故障。
- 每轮确认诊断会生成仅当前用户可读的脱敏状态文件，供本机或远程 Agent 查询。

### 2.2 新增

- 展开面板右上角独立显示 Clash 的规则、全局或直连模式；随已确认检测刷新，读取不到时显示“模式未知”，不与网络健康状态混淆。
- 节点延迟正常但经 Clash 的真实外站流量连续失败时，提示“节点假绿：疑似入口拨号失败”；旧流量计数不覆盖本轮真实失败。
- 独立入口自愈默认关闭，在诊断面板“入口自愈”设置中明确启用。

## 下载与安装

下载当前预览版：

1. 打开 [ProxySentry 2.2.1 Preview](https://github.com/justinjia0813/ProxySentry/releases/tag/preview-v2.2.1)。
2. 在 **Assets** 中下载 macOS 通用构建，而不是 GitHub 自动生成的源码压缩包。
3. 解压，将 `ProxySentry.app` 拖入“应用程序”，然后打开。

当前公开包的文件名带有 `-unsigned`，代表它是未签名预览版。若要试用，请右键应用并选择“打开”；必要时前往“系统设置 → 隐私与安全性”确认。详见 [Apple 的安全设置说明](https://support.apple.com/guide/mac-help/mh40616/mac)。不要通过关闭 Gatekeeper 或运行来源不明的解除隔离命令来安装。

签名且公证通过的正式版发布后，下载入口会切换到 GitHub 的 Latest Release。

## 四层诊断

| 检查项 | 回答的问题 | `WAIT` 代表什么 |
| --- | --- | --- |
| `base` | 网卡、默认网关和直连公网是否正常？ | 证据仍不足或检测尚未完成。 |
| `traffic` | 真实外站请求能否通过代理出口完成？缺少真实探测时回退到聚合流量观察。 | 暂时没有足够证据，不等于失败。 |
| `proxy` | 当前代理节点能否连通，延迟如何？ | 暂时无法形成可靠结论。 |
| `clash` | Clash Verge Rev 的 Mihomo 内核和本地接口是否可用？ | 内核状态尚未确认。 |

状态颜色保持一致：绿色正常，橙色需要关注，红色故障，灰色未知。面板同时保留异常摘要，避免只有颜色没有原因。

## 给远程 Agent 读取

ProxySentry 每轮确认诊断后，会把同一份脱敏证据原子写入 JavaScript Object Notation（JSON，JavaScript 对象表示法；便于程序读取的结构化文本格式）文件：

```text
~/Library/Application Support/ProxySentry/agent-status.json
```

在手机端连接远程 Mac 的 Agent 后，可以直接要求它“读取 ProxySentry 的 agent-status.json，报告这台 Mac 的直连、代理、节点和 Clash 状态”。文件包含 `checkedAt`、`expiresAt`、主结论和逐项证据；缺少某类证据时，`missingEvidence` 明确规定该层为 `unknown`（未知），不代表成功或失败。当前时间晚于 `expiresAt` 时，Agent 必须说明状态已过期，并提示确认 ProxySentry 是否仍在运行，不能把旧结果当作当前网络。

该文件权限为仅当前 macOS 用户可读写，不包含原始连接、节点名称、订阅地址、访问密钥或原始 Clash 响应。它只供已能在这台 Mac 上执行命令的本地或远程 Agent 读取，不开放网络端口，也不提供远程控制。

## 常见问题：手机能用，电脑上的 Clash 却全节点超时

这不一定是节点本身停机。若面板同时显示 `proxy PASS` 与 `traffic TIMEOUT`，代表 Clash 的节点延迟探测成功，但两个真实外站请求都无法经 Clash 出口完成；可能是机场入口解析命中了失效地址。诊断只报告“疑似”，不把超时等同于已证实被墙；默认不修改配置。

## 可选入口自愈（默认关闭）

打开诊断面板 → 入口自愈 → 检查运行条件。需要自愈时再启用并确认提示。如果运行配置和订阅都已经固定为地址，需要填写原始入口域名。

- 仅支持 Clash Verge Rev 全局模式中直接选中的 VLESS REALITY 节点；不支持嵌套策略组、其他协议、自定义配置目录或开启虚拟网卡的场景。不满足条件就停止，不猜测目标节点。
- 主进程只向独立辅助进程提供已确认且未过期的红色诊断。辅助进程复核基础网络、本地端口、内核和两个真实外站失败；单次抖动不触发，每 180 秒最多尝试一次，同一诊断不重放。
- 从阿里、腾讯的公共解析器及 Google、Cloudflare 的加密解析服务取候选地址，在隔离的临时内核中核对节点延迟和两个真实外站请求。全部通过才备份并仅修改当前节点的入口地址，重载后再次验证真实流量。
- 写入前重新核对当前节点、当前订阅、配置内容和启用状态；失败或停止时回滚。发现外部修改时不覆盖，保留备份并报告需要人工处理。异常退出留下的事务会在下次已启用的辅助进程启动时尝试安全恢复。
- 检测到 `com.justinjia.clash-watchdog.plist` 或旧锁文件时拒绝接管。请先手动停用旧看门狗并将其登录项移出 `~/Library/LaunchAgents/`；本工具不会替你停用或删除旧脚本。
- 关闭自愈或退出应用后不再启动修复；正在执行的事务先安全收尾。没有新增后台登录项或常驻服务，也不会切换节点、更改系统代理。

辅助进程使用系统 `/usr/bin/ruby`、`/usr/bin/dig`（可选的直连解析）和已安装的 Clash 内核，不安装第三方依赖。单次尝试预算 90 秒，随后可能需要有限时间回滚。配置格式不支持、候选均失败、基础网络不可独立判断时只报告，不写配置。

`~/Library/Application Support/ProxySentry/` 下新增：

- `watchdog-settings.json`：启用状态和可选原始域名。
- `watchdog-status.json`：脱敏状态码及有效期，远程 Agent 可只读查询；过期状态不能当作当前结果。
- `watchdog-attempt.json`、`watchdog.lock`：防重放、冷却和单实例控制。
- `watchdog-backups/`、`watchdog-journal.json`：私有备份和未完成事务。**备份包含原配置中的节点凭据，不应上传、提交或分享。** 自动恢复失败时保留记录，不自动覆盖外部修改；备份不自动清理，由用户在确认不再需要恢复后自行管理。

源码验证：`/usr/bin/ruby ProxySentryTests/watchdog_test.rb`；应用测试使用 Xcode。测试只使用临时配置，不启用或修复本机 Clash。

## 隐私与权限

诊断主进程保持只读：

- 不切换节点，不修改 Clash 配置，不接管系统代理。
- 只读访问 Clash Verge Rev 的本地 Unix socket，并只读取白名单接口的聚合结果。
- 不上传或持久化原始连接、节点名称、订阅地址、访问密钥或原始响应。
- 仅在运行期间周期性探测 Apple 中国站、百度、Google、Cloudflare，以及 `1.1.1.1:443` 和 `223.5.5.5:443`。Domain Name System（DNS，域名系统；把域名解析为网络地址）或目标站点策略可能影响检测结果。

用户主动启用的独立自愈进程是上述“不修改配置、不保存凭据”边界的明确例外：它只为当前节点修复读取配置、生成私有临时配置及恢复备份，不把凭据放入状态文件、命令行或继承的环境。原始入口域名会发给上述四家解析服务，其中公共解析器请求未加密；修复验证产生到候选入口和两个外站的网络请求。

ProxySentry 不是 Clash Verge Rev 官方产品，与 Clash Verge Rev、Mihomo、Apple、百度、Google、Cloudflare 或阿里云均无官方关联或背书。

## 系统要求

- macOS 13 或更高版本。
- Apple 芯片与 Intel 芯片；发布包为 `arm64` 和 `x86_64` 通用构建。
- 当前明确支持 Clash Verge Rev；其他 Clash 客户端和自定义 socket 路径尚未承诺兼容。

## 从源码构建

需要 Xcode 和 macOS 开发工具：

```sh
xcodebuild -project ProxySentry.xcodeproj -scheme ProxySentry -configuration Debug \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

生成与项目版本一致的未签名本地预览包：

```sh
./scripts/package-release.sh
```

脚本会检查通用架构、macOS 13.0 最低版本，并在 `dist/` 生成压缩包和 Secure Hash Algorithm 256-bit（SHA-256，256 位安全散列算法；用于核对下载文件是否被改动）校验文件。本地构建不等于 Developer ID 签名或 Apple 公证。

## 发布可信度

截至 2026-09-05：

| 项目 | 状态 |
| --- | --- |
| 2.2 源码与通用构建 | 通过发布工作流测试与打包 |
| GitHub Release 下载入口 | `preview-v2.2.1` 未签名预览版 |
| Developer ID 签名 | 未完成；本机没有可用签名身份 |
| Apple 公证与票据装订 | 未完成 |
| Gatekeeper 验证 | 当前公开包会被拒绝 |
| 自动更新 | 暂无 |

只有在最终上传的同一份应用完成 Developer ID 签名、Apple 公证、票据装订，并通过签名与 Gatekeeper 检查后，才会标记为正式发布。详细证据和发布门槛见 [发布合规审计](docs/release-distribution-audit.md)。

## 参与贡献

欢迎提交 [Issue](https://github.com/justinjia0813/ProxySentry/issues) 和 Pull Request。提交前请运行相关测试和 `git diff --check`；不要提交 Clash 访问密钥、订阅地址、原始连接日志或个人信息。更多约定见 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [SECURITY.md](SECURITY.md)。

## 许可证

项目采用 [Massachusetts Institute of Technology License（MIT License，麻省理工学院许可证；允许使用、修改和再分发的宽松开源许可证）](LICENSE)。
