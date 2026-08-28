# ProxySentry 实现计划

状态：已实现；待有效开发签名下的登录启动与菜单栏现场验收

日期：2026-08-27

设计依据：[2026-08-27-proxy-sentry-design.md](../specs/2026-08-27-proxy-sentry-design.md)

## 1. 交付结果

交付一个可在当前 Apple Silicon Mac 上运行的原生菜单栏应用。它每 15 秒及网络变化时诊断直连和代理链路，用五种状态区分直连正常、本机代理异常、疑似机场或节点异常、代理正常以及无法定位；Clash Verge Rev 信息读取失败时，通用诊断仍正常工作。

实现遵循 Test-Driven Development（TDD，测试驱动开发），即先建立会失败的检查，再写通过该检查的最小代码。首版不新增第三方依赖、不增加设置页、不自动修复网络，也不为后续功能预留空接口。

## 2. 已确认环境与工程决策

- Xcode 26.6、Swift 6.3.3、macOS 26.5 Software Development Kit（SDK，软件开发工具包），可直接构建原生应用。
- 最低部署版本设为 macOS 26.0，只服务当前机器，不承担旧系统兼容成本。
- 使用一个 macOS Application target 和一个 Unit Test target。
- 使用 `NSStatusItem`、`NSPopover` 和 `NSHostingController`：AppKit 管理菜单栏与生命周期，SwiftUI 负责弹出面板。
- 使用 Xcode 自带工程格式；不安装 XcodeGen、Tuist、格式化器或静态检查器。
- App Sandbox 关闭；不申请管理员权限、网络扩展、辅助功能或 Apple Events 权限。
- 本地 Bundle Identifier 使用 `com.justinjia.ProxySentry`。
- 只做本地开发签名；公开分发所需的 Developer ID、公证和自动更新不在首版范围。
- 2026-08-27 检查到本机没有有效代码签名身份。无签名路径使用 `CODE_SIGNING_ALLOWED=NO` 完成诊断、界面与自动测试；登录启动保持“签名不可用”状态。若用户之后在 Xcode 提供本地开发签名，再执行 Service Management（SM，服务管理）框架 `SMAppService.mainApp` 的注册、取消和审批验收。

工程文件由 Xcode 原生创建，避免手写易损的 `project.pbxproj`，随后所有源文件和测试由补丁编辑。登录启动默认开启是用户在设计阶段明确批准的行为，但只有签名可用时才实际注册；否则不伪造成功。

## 3. 最小文件结构

```text
ProxySentry.xcodeproj/
.gitignore
ProxySentry/
  Info.plist
  ProxySentryApp.swift
  Diagnosis.swift
  SystemNetwork.swift
  NetworkProbes.swift
  ClashReader.swift
  DiagnosticsController.swift
  StatusPopoverView.swift
  SystemServices.swift
ProxySentryTests/
  DiagnosisTests.swift
  SystemNetworkTests.swift
  NetworkProbesTests.swift
  ClashReaderTests.swift
  DiagnosticsControllerTests.swift
  SystemServicesTests.swift
docs/superpowers/
  specs/2026-08-27-proxy-sentry-design.md
  plans/2026-08-27-proxy-sentry-implementation.md
```

只在独立测试 seam 或并行文件所有权确有需要时分文件；不创建一实现接口、工厂、仓储层或通用工具目录。

## 4. 依赖顺序与并行边界

```text
任务 0 工程骨架
  ↓
任务 1 状态模型与分类器
  ↓
任务 2 防抖与调度核心
  ├─ 任务 3 系统网络与代理观察 → 任务 4 网络探针
  └─ 任务 5 Clash 只读增强
       ↓
任务 6 诊断整合
  ↓
任务 7 菜单栏界面
  ↓
任务 8 通知、登录启动和打开 Clash
  ↓
任务 9 全量验证与本机验收
```

任务 3 与任务 5 可由 Luna 执行代理并行完成；任务 4 在任务 3 的 `ProxySnapshot` 固定后再执行。三项分别只拥有 `SystemNetwork.swift`、`NetworkProbes.swift`、`ClashReader.swift` 及对应测试。一个集成者负责共享的 Xcode 工程、`Diagnosis.swift`、`DiagnosticsController.swift` 和最终合并，不允许并发修改共享文件。并行执行者不暂存、不提交；集成者验证后按下述本地提交边界提交。

## 5. 任务清单

### 任务 0：建立可构建的菜单栏工程

**文件**

- 创建 `ProxySentry.xcodeproj`
- 创建 `.gitignore`
- 创建 `ProxySentry/Info.plist`
- 创建 `ProxySentry/ProxySentryApp.swift`
- 创建空的 `ProxySentryTests` target

**步骤**

1. 用 Xcode 原生模板创建 macOS App，界面语言选 SwiftUI，测试使用 Swift Testing；删除模板窗口和默认 `ContentView`。
2. 设置 `MACOSX_DEPLOYMENT_TARGET = 26.0`、`PRODUCT_BUNDLE_IDENTIFIER = com.justinjia.ProxySentry`、`GENERATE_INFOPLIST_FILE = NO`、`INFOPLIST_FILE = ProxySentry/Info.plist`，关闭 App Sandbox。
3. 在 `.gitignore` 忽略 `.build/`、Derived Data 和 Xcode 用户状态；在唯一的 `Info.plist` 设置 `LSUIElement = true`，确保应用不显示 Dock 图标。
4. 写最小 `NSApplicationDelegate`，创建一个方形 `NSStatusItem` 和临时 `NSPopover`；图标使用系统符号，不添加图片资源。
5. 使用 Xcode 的文件系统同步组管理 `ProxySentry/` 和 `ProxySentryTests/`，使后续新增文件自动进入对应 target；若模板未生成同步组，只由集成者一次性维护 target membership。
6. 共享 `ProxySentry` scheme，保证命令行可测试。
7. 运行 `security find-identity -v -p codesigning` 记录签名路径：当前无身份时走无签名构建；只有实际出现有效开发身份时才进入登录项验收。

**检查**

```sh
xcodebuild -project ProxySentry.xcodeproj -scheme ProxySentry -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ProxySentry.xcodeproj -scheme ProxySentry -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```

手动启动一次，确认只有菜单栏图标、没有 Dock 图标，点击能打开和关闭空面板。若颜色在菜单栏被系统模板化，立即改用非模板系统符号渲染，不增加自定义资源。

**本地提交边界**：`build: create minimal menu bar app`

### 任务 1：先完成纯状态模型与分类器

**文件**

- 创建 `ProxySentry/Diagnosis.swift`
- 创建 `ProxySentryTests/DiagnosisTests.swift`

**先写失败测试**

用表驱动覆盖：

1. 代理路径已配置或虚拟网卡已启用，且代理出口成功时绿色优先；没有代理路径时单独的成功样本不得判绿。
2. 无系统代理、无虚拟网卡且直连成功时蓝色。
3. 基础网络正常但本地代理端口不可达时黄色。
4. 代理路径已配置或虚拟网卡已启用、直连至少一个目标成功、系统代理端口与 Clash 运行端口匹配且可达、`/version` 与 `/configs` 均成功、两个代理目标连续两轮全部失败时红色。
5. 无代理但有无关监听端口、只有 `/version` 成功、端口不匹配、Clash 信息不可用、Proxy Auto-Configuration（PAC，代理自动配置）未解析、虚拟网卡使直连不可独立判断、直连与代理同时失败时不得输出红色。
6. 证据不足时灰色，并包含最小缺口说明。
7. 诊断摘要不包含 secret、订阅地址或完整节点清单。

**最小实现**

- `ProbeOutcome`：`success`、`failure`、`timeout`、`unavailable`。
- `ProbeEvidence`：类别、结果、毫秒耗时、用户可见说明；不允许存放原始配置或响应。
- `NetworkSnapshot`：一轮分类所需的有限布尔值和证据。
- `DiagnosisState`：绿色、蓝色、黄色、红色、灰色及图标、颜色、标题映射。
- `DiagnosisClassifier.classify(_:)`：纯函数，严格按设计优先级返回唯一状态。

不要在模型中加入控制密钥、订阅地址或完整 Clash JavaScript Object Notation（JSON，JavaScript 对象表示法）响应字段。

**检查**

```sh
xcodebuild -project ProxySentry.xcodeproj -scheme ProxySentry -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test -only-testing:ProxySentryTests/DiagnosisTests
```

**本地提交边界**：`feat: add diagnosis classifier`

### 任务 2：实现防抖与单通道调度

**文件**

- 更新 `ProxySentry/Diagnosis.swift`
- 创建 `ProxySentry/DiagnosticsController.swift`
- 创建 `ProxySentryTests/DiagnosticsControllerTests.swift`

**先写失败测试**

1. 单次异常只产生候选状态，不提交也不通知。
2. 连续两轮相同异常提交一次。
3. 连续两轮恢复提交一次恢复状态。
4. 相同已提交状态不重复通知。
5. 多个触发在诊断运行中合并为最多一次补充诊断，最大并发始终为一。
6. 取消后不再提交迟到结果。
7. 用可控睡眠替身推进两秒复检和八秒总预算；八秒到达时所有未完成探针被取消。

**最小实现**

- `StateDebouncer.accept(_:)` 只处理连续结果计数，不注入时钟。
- `DiagnosticsController` 使用一个顺序消费的 `AsyncStream`，缓冲策略为 newest-one，统一接收定时、路径变化、代理变化、唤醒和手动复检。
- `DiagnosticsController` 只注入一个 `sleep` 闭包作为时间 seam；生产使用连续时钟，测试即时推进，不创建通用时钟协议。
- 15 秒定时任务只发送触发事件；异常候选产生后通过同一 sleep seam 安排两秒复检。
- 每轮诊断由结构化并发执行，八秒到达后取消剩余探针；结果只在主 actor 提交给界面。

**检查**

```sh
xcodebuild -project ProxySentry.xcodeproj -scheme ProxySentry -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test -only-testing:ProxySentryTests/DiagnosticsControllerTests
```

**本地提交边界**：`feat: serialize diagnosis scheduling`

### 任务 3：读取并监听系统网络与代理

**所有权**

- 创建 `ProxySentry/SystemNetwork.swift`
- 创建 `ProxySentryTests/SystemNetworkTests.swift`

**先写失败测试**

用固定代理字典覆盖：无代理、Hypertext Transfer Protocol（HTTP，超文本传输协议）代理、Hypertext Transfer Protocol Secure（HTTPS，超文本传输安全协议）代理、Socket Secure（SOCKS，安全套接字代理）代理、PAC、自动发现、缺主机、缺端口和非本机代理。

**最小实现**

- `NWPathMonitor` 只产出路径是否满足、接口类型和是否支持域名解析；不把 `satisfied` 当作互联网成功。
- `SCDynamicStoreCopyProxies(nil)` 读取当前系统代理快照。
- `SCDynamicStoreKeyCreateProxies` 加动态存储回调，并用 `SCDynamicStoreSetDispatchQueue` 绑定专用串行队列；观察器强持有动态存储对象直到停止，代理变化时只发送一次调度触发，终止时解除队列。
- 固定端口代理解析为 `ProxySnapshot`；PAC 和自动发现只标记为已启用但不可直接探测，不在首版执行脚本。
- 睡眠唤醒与会话恢复通过 `NSWorkspace.shared.notificationCenter` 触发重测。

**检查**

```sh
xcodebuild -project ProxySentry.xcodeproj -scheme ProxySentry -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test -only-testing:ProxySentryTests/SystemNetworkTests
```

本机切换一次系统代理，确认只触发复检，不修改系统设置。

自动测试用回调闭包断言一次代理变化恰好产生一次调度事件，并验证停止观察后不再触发。

**本地提交边界**：`feat: observe network and proxy changes`

### 任务 4：实现可取消的网络探针

**所有权**

- 创建 `ProxySentry/NetworkProbes.swift`
- 创建 `ProxySentryTests/NetworkProbesTests.swift`

**先写失败测试**

1. 域名解析成功、失败和三秒超时。
2. 显式直连会话关闭 HTTP、HTTPS、SOCKS、PAC 和自动发现设置。
3. 显式代理会话使用发现的本地代理主机和端口。
4. 两个目标任一成功即证明路径可用；全部失败才返回失败。
5. 本地端口连接拒绝、成功、超时和任务取消。
6. 只输出错误类别和耗时，不输出目标请求内容或底层敏感错误。
7. 用测试内回环监听器充当代理陷阱：对保留的 `.invalid` 域名发请求时，显式直连会话不得命中监听器，显式代理会话必须命中并发送代理握手；测试不修改系统代理也不访问公网。

**最小实现**

- 域名解析：系统解析器，目标为 `apple.com.cn` 和 `baidu.com`。
- 直连 HTTPS 探针：`https://www.apple.com.cn/library/test/success.html`、`https://www.baidu.com/favicon.ico`。
- 代理 HTTPS 探针：`https://www.gstatic.com/generate_204`、`https://cp.cloudflare.com/generate_204`。
- 请求使用 `GET`，禁止自动重定向并设置 4 kilobytes（KB，千字节）最大响应体；Apple 与 Baidu 目标只接受 200，Google 与 Cloudflare 目标只接受 204，单目标三秒超时。
- 本地端口使用 `NWConnection`；仅连接验证，不发送业务数据。
- 对透明虚拟网卡无法绕过的情形返回 `unavailable`，不声称真正直连。
- 自动测试通过 `URLProtocol` 和注入的解析闭包返回固定结果，不访问真实公共目标；真实目标只在本机只读冒烟测试中使用。
- 另用真实 `URLSession` 和测试内回环监听器验证连接路径；监听器只记录是否命中和请求方法，不保存请求内容。

固定目标是可重复验收的一部分，实施中不根据一次本机结果自动替换，也不增加可配置目标界面。单个目标失败由同类第二目标交叉验证；两个目标同时失败才产生路径失败证据。

**检查**

```sh
xcodebuild -project ProxySentry.xcodeproj -scheme ProxySentry -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test -only-testing:ProxySentryTests/NetworkProbesTests
```

**本地提交边界**：`feat: add network probes`

### 任务 5：实现 Clash Verge Rev 只读增强

**所有权**

- 创建 `ProxySentry/ClashReader.swift`
- 创建 `ProxySentryTests/ClashReaderTests.swift`

**先写失败测试**

1. 只接受有限套接字路径白名单：当前用户临时目录下的 `verge-mihomo.sock`、`/tmp/verge/verge-mihomo.sock`、用户目录 `.config/verge/verge-mihomo.sock`。父目录和套接字所有者只能是当前用户或 root，父目录不得被组内或其他用户写入，并拒绝非套接字、目录外路径、扫描发现或任意配置文件名。
2. 解析白名单配置字段，不读取 `profiles`、日志、缓存或订阅文件。
3. Unix 域套接字连接拒绝、超时、非 2xx、响应截断、响应超限和字段缺失全部返回增强信息不可用。
4. 固定样本覆盖 `Content-Length`、`Transfer-Encoding: chunked` 和连接关闭结束三种响应，以及畸形分块安全失败。
5. `/version`、`/configs`、`/proxies` 固定响应只提取内核版本、虚拟网卡状态、主要代理组当前选择和已有延迟。
6. 控制密钥、订阅地址、完整节点数组和供应商字段不进入模型、摘要、通知或测试失败输出。
7. 连接与读取分别在三秒内超时；任务取消或任一超时都关闭底层连接，且迟到数据不得回调。

**最小实现**

- 5.0.7 先尝试 `confstr(_CS_DARWIN_USER_TEMP_DIR)` 下的固定文件名；2.4.7 只尝试固定 `/tmp/verge` 与用户目录 `.config/verge` 路径。配置声明的路径只有规范化后与这三个白名单候选之一完全相等才接受；不遍历目录。连接前用文件属性和权限位验证父目录及套接字，不安全候选直接跳过。
- 用 `NWEndpoint.unix(path:)` 发送只读 GET 请求，不执行节点切换或测速。
- 每次连接和读取各有独立三秒截止；用取消处理器关闭 `NWConnection`，确保超时、上层任务取消和解析失败都不会留下后台读取。
- 原生解析最小 HTTP 响应；接受 2xx，并支持 `Content-Length`、分块传输和连接关闭结束，解码后响应体上限为 1 megabyte（MB，兆字节）；截断、超限和畸形响应安全降级。
- 用 `JSONSerialization` 读取有限字段；主要代理组优先 `GLOBAL`，否则取第一个有 `now` 字段的 selector，并标注为“Clash 当前选择”，不声称它代表每条连接的实际路由。
- Unix 套接字失败时，仅在运行配置存在合法回环地址和端口时尝试网络控制接口；不依赖 Clash Verge 的界面开关字段。密钥只在内存内构造授权头，绝不进入命令行、日志或模型。
- 外部控制器地址不是回环地址时直接降级，不连接局域网或公网控制端口。
- 配置读取只扫描列首白名单键，支持未加引号、单引号和双引号标量；不实现完整 YAML Ain't Markup Language（YAML，YAML 不是标记语言）解析器，这是一种结构化配置文本格式。遇到重复键、别名、块字符串、未知缩进或复杂标量时直接返回不可用。
- 2026-08-27 本机只读检查观察到套接字连接失败；这是动态检查结果，不作为稳定前提。无论后续能否读取，验收都要求通用诊断完整返回。

**检查**

```sh
xcodebuild -project ProxySentry.xcodeproj -scheme ProxySentry -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test -only-testing:ProxySentryTests/ClashReaderTests
```

本机只读冒烟测试不得输出 secret、订阅地址、节点清单或原始响应。

**本地提交边界**：`feat: read optional Clash status`

### 任务 6：整合一轮诊断

**文件**

- 更新 `ProxySentry/DiagnosticsController.swift`
- 更新 `ProxySentryTests/DiagnosticsControllerTests.swift`

**先写失败测试**

1. 按系统路径、域名解析、直连、系统代理、本地端口、代理出口、Clash 增强顺序形成一轮证据。
2. 独立探针可并发，但分类必须等待必要证据或八秒总预算结束。
3. Clash 增强失败不覆盖已成功的代理或直连结论。
4. 红色只在全部门槛存在时产生；代理成功始终绿色优先。
5. 手动复检立即触发，运行中重复点击只合并一次。
6. 可控睡眠推进到八秒时取消全部未完成探针，迟到结果不得更新状态。

**最小实现**

- 用闭包注入路径、代理、网络探针和 Clash 读取函数；不为单实现创建协议层。
- 先固定系统路径和代理快照，再并发执行依赖该快照的域名、直连、本地端口、代理出口与 Clash 探针；同一轮不得混用变化前后的代理端点。
- `DiagnosticsController` 发布当前状态、候选状态、是否检测中、最近时间和非敏感证据。
- 摘要在模型边界由白名单字段生成，界面不得拼接底层错误对象。

**检查**

```sh
xcodebuild -project ProxySentry.xcodeproj -scheme ProxySentry -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```

**本地提交边界**：`feat: integrate diagnosis pipeline`

### 任务 7：完成菜单栏和展开面板

**文件**

- 更新 `ProxySentry/ProxySentryApp.swift`
- 创建 `ProxySentry/StatusPopoverView.swift`

**步骤**

1. `NSStatusItem` 固定 `squareLength`，使用不同系统符号和颜色映射五种状态。
2. 设置动态 accessibility label 和 value；自身界面不请求辅助功能信任权限。
3. `NSPopover` 使用 transient 行为，SwiftUI 面板显示主状态、检测时间、Clash 摘要、失败证据、成功证据和检测中状态。
4. 加入立即复检、打开 Clash、复制诊断摘要、登录时启动和退出应用。
5. 失败证据优先，底层错误码和密钥永不进入界面。

**检查**

- 渲染并检查浅色、深色菜单栏；五种图标不只依赖颜色。
- 检查刘海两侧空间、面板裁切、文字完整性、VoiceOver 和完整键盘控制。
- 连续快速点击图标，面板不重复创建且不会失去锚点。

**本地提交边界**：`feat: add status menu interface`

### 任务 8：接入系统通知、登录启动和打开 Clash

**文件**

- 创建 `ProxySentry/SystemServices.swift`
- 创建 `ProxySentryTests/SystemServicesTests.swift`
- 更新 `ProxySentry/StatusPopoverView.swift`
- 更新 `ProxySentry/DiagnosticsController.swift`

**先写失败测试**

1. 已提交状态变化只通知一次；相同状态不通知；绿色或蓝色恢复通知一次。
2. 通知权限拒绝不影响诊断。
3. 登录项状态正确映射 `notRegistered`、`enabled`、`requiresApproval` 和 `notFound`。
4. Clash 启动严格按白名单选择：先找 `/Applications/Clash Verge.app` 的 5.0.7，再找用户 Applications 目录的 5.0.7，之后才允许 2.4.7 兼容回退；其他版本不自动启动。
5. 无签名自动测试通过闭包替身覆盖通知授权、通知发送、登录项注册和系统设置跳转，不弹真实权限框也不写真实登录项。
6. `UserDefaults` 只保存登录启动偏好和是否已尝试注册；首次失败后重启应用不重复注册，用户重新打开开关才允许重试。

**最小实现**

- `UNUserNotificationCenter` 首次请求 alert 权限，不使用声音。
- `SMAppService.mainApp` 注册或取消登录启动；需要用户批准时提供打开系统设置的动作。
- 首次启动没有已有偏好时按用户已批准的设计默认尝试启用登录启动；记录尝试结果，以后只服从面板开关和系统返回状态，不因注册失败在每次启动重复轰炸系统。
- 系统对象只包成最小操作闭包；通知决策、登录状态映射和版本选择保持纯函数，自动测试不调用真实系统服务。
- `UserDefaults` 仅使用 `loginAtLaunchDesired` 与 `loginRegistrationAttempted` 两个键，不保存诊断结果、网络地址或 Clash 信息。
- 未签名构建明确显示“登录启动不可用”，不写 LaunchAgent，也不创建 helper target。
- 打开 Clash 时只按上述路径和 5.0.7、2.4.7 白名单选择；Bundle Identifier 查询只用于定位候选，版本不在白名单时拒绝启动并显示非阻塞提示。
- 复制摘要使用系统剪贴板，只复制白名单摘要。

**检查**

无签名路径必须运行：

```sh
xcodebuild -project ProxySentry.xcodeproj -scheme ProxySentry -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```

只有 `security find-identity` 返回有效开发身份后才运行：

```sh
xcodebuild -project ProxySentry.xcodeproj -scheme ProxySentry -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build
codesign --verify --deep --strict .build/xcode/Build/Products/Debug/ProxySentry.app
codesign -dv --verbose=2 .build/xcode/Build/Products/Debug/ProxySentry.app
```

签名构建和登录项注册只在已获得有效开发签名时运行；当前无签名路径明确记录“登录启动未验收”。若安装到 `/Applications` 才能完成登录项验收，先停下并请求用户批准外部写入。

**本地提交边界**：`feat: add notifications and login item`

### 任务 9：全量验证与本机验收

**自动检查**

```sh
xcodebuild -project ProxySentry.xcodeproj -scheme ProxySentry -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO clean test
git diff --check
git diff --cached --check
git status --short
git status --short --ignored
```

**本机场景**

1. 关闭系统代理且直连正常：蓝色。
2. Clash 正常、系统代理启用、代理出口可用：绿色。
3. 保持系统代理启用但退出 Clash：黄色。
4. 测试替身注入本地链路正常、两个代理出口失败、Clash 正常：红色；不修改真实 Clash 配置。
5. 断开无线网络：灰色。
6. 睡眠再唤醒：立即复检，不补跑睡眠期间定时任务。
7. 每种状态稳定一分钟：没有重复通知。
8. 正常空闲五分钟：没有重叠任务或忙循环，平均处理器占用低于 1%。
9. Clash 只读接口不可用：面板显示详情不可用，通用诊断仍给出状态。

处理器验收使用 Process Identifier（PID，进程标识符）锁定 ProxySentry 进程；PID 用来唯一定位本次运行的应用。`top` 每 30 秒采样一次，共 11 次，丢弃首个预热样本，对后 10 次 Central Processing Unit（CPU，中央处理器）占用求平均，并同时观察任务最大并发计数始终为一：

```sh
proxy_sentry_pid=$(pgrep -x ProxySentry)
top -pid "$proxy_sentry_pid" -l 11 -s 30 -stats pid,cpu,mem
```

**视觉与可访问性**

- 实际运行应用并截图检查图标、颜色、面板布局、裁切、间距和深浅色一致性。
- 用 VoiceOver 和完整键盘控制走完全部按钮与开关。

**安全检查**

- 在生产源代码中扫描真实 secret 和订阅地址；在测试输出、构建日志、诊断摘要、通知和剪贴板样本中扫描测试夹具的 canary 值。扫描工具只返回通过或失败和命中数量，不打印匹配行、原始响应或夹具内容。
- 确认应用未写诊断历史、未监听对外端口、未修改系统代理或 Clash 配置。
- 检查忽略、未跟踪和暂存文件，报告实际构建、提交和安装状态。

**本地提交边界**：`test: verify ProxySentry end to end`

## 6. 实施停止规则

- 某个探针连续失败时先用一个替身测试和一个本机只读检查定位；最多再尝试一个有意义回退，不通过读取 Clash 日志或订阅内容猜测。
- 当前 Clash 私有套接字不可用不是阻塞条件；只有通用诊断也无法工作才阻塞首版。
- PAC、透明虚拟网卡或虚拟专用网络导致路径不可隔离时返回灰色，不扩大到网络扩展或流量截获。
- 登录启动因签名或系统批准失败时保留明确不可用状态，不写 LaunchAgent 绕过系统机制。
- 当前没有代码签名身份时先完成无签名诊断版本；最终交付前把“登录启动尚未验收”列为唯一外部门槛，并由用户选择提供开发签名或接受该功能暂不可用。
- 任何需要写入 `/Applications`、修改系统网络设置、修改 Clash、推送远程或公开分发的动作，执行前单独获得用户确认。
- 自动测试、五种状态、本机视觉检查和隐私扫描通过后结束；不顺手增加历史记录、自动修复、更多代理客户端或设置页。

## 7. 官方依据

- [Apple NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)
- [Apple NWPathMonitor](https://developer.apple.com/documentation/network/nwpathmonitor)
- [Apple SCDynamicStoreCopyProxies](https://developer.apple.com/documentation/systemconfiguration/scdynamicstorecopyproxies%28_%3A%29)
- [Apple UNUserNotificationCenter](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter)
- [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [mihomo Application Programming Interface（API，应用程序编程接口）](https://wiki.metacubex.one/en/api/)；这是程序之间交换状态的约定接口。
- [Clash Verge Rev v2.4.7 目录与本机通信源码](https://github.com/clash-verge-rev/clash-verge-rev/blob/v2.4.7/src-tauri/src/utils/dirs.rs)；当前安装的 5.0.7 没有对应官方仓库标签，因此本机只读行为与安全降级规则优先于源码推断。
