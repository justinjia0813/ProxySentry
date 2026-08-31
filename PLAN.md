# ProxySentry 2.0 当前实施计划

## 目标

保留现有诊断核心、证据分层和只读边界，把当前本地 v0.1.0 的菜单栏弹出面板演进为 2.0 刘海浮窗：平时收纳在刘海区域，必要时以终端风格胶囊展开，仍然不显示菜单栏或 Dock 图标。

核心诊断逻辑不变：继续区分基础网络、系统代理、Clash 内核和当前节点；Clash 私有接口仍只是可失效增强层，不能阻塞通用诊断。

## 当前实现与交互改造

- 当前代码实际由 `ProxySentryApp.swift` 每 60 秒触发一轮后台检查；2.0 不改为 15 秒，也不因 60 秒定时检查打扰用户。
- 关闭状态显示一个紧凑的刘海胶囊；鼠标悬停或网络状态变化时短暂展开，展示 `base / traffic / proxy / clash` 四行终端矩阵。
- 网络变化触发展开和立即复检；60 秒周期检查只更新状态，不主动展开。
- 鼠标离开、外部点击或 Escape 后收起；外部点击只通过公开的只读鼠标事件监视器观察，不拦截其他应用输入。收起不能停止诊断，也不能清除当前证据。
- 有刘海的屏幕优先使用刘海左右的可用区域；无刘海的外接屏或普通屏幕退化为顶部胶囊，不伪造刘海形状。
- 浅色、深色、长中文、异常溢出、全屏 Space 和多屏切换都必须保持可读和可操作。

## 公开 API 与几何降级

只使用公开 AppKit API（Application Programming Interface，应用程序编程接口；系统允许应用调用的接口）：`NSScreen.safeAreaInsets`、`auxiliaryTopLeftArea`、`auxiliaryTopRightArea`、`visibleFrame`、`NSPanel` 和公开的 `NSWindow.CollectionBehavior`。

禁止使用 SkyLight、Core Graphics Services（CGS，核心图形服务；macOS 私有窗口管理接口）或其他私有 API；不申请辅助功能权限，不模拟键盘或鼠标，也不拦截其他应用输入。

屏幕选择按浮窗触发来源的屏幕优先，屏幕对象缺失时安全退化到可见屏幕。几何计算必须与 `NSScreen` 解耦为可测试的矩形/尺寸输入，并覆盖刘海、无刘海、负坐标、多屏、Dock/菜单栏和过宽内容。

## 文件所有权

- 主代理：`ProxySentry/ProxySentryApp.swift`、`ProxySentry/StatusPopoverView.swift`、`ProxySentryTests/ProxySentryAppTests.swift`、`ProxySentryTests/VisualSnapshotTests.swift`，负责浮窗生命周期、终端界面和集成验收。
- 诊断相关文件保持不变，除非验证发现 2.0 UI 接口确实需要最小适配。
- 不新增第三方依赖，不修改 Clash 读取、网络探针、诊断分类和通知语义。

## 验证

- `xcodebuild` Debug 测试：保持现有全部测试通过，并增加浮窗几何、生命周期和矩阵语义测试。
- `xcodebuild` Release 无签名构建：验证 macOS 13.0、arm64 与 x86_64 通用产物。
- 视觉验收：刘海 MacBook、无刘海外接屏、多屏、浅色/深色、全屏 Space、长文本和异常溢出；检查无裁切、重叠或屏幕外定位。
- 交互验收：hover 展开、网络变化短暂展开、鼠标离开/外部点击/Escape 收起；确认 60 秒定时不展开、不重复通知。
- 辅助功能验收：VoiceOver（macOS 屏幕阅读器）可读状态、矩阵和操作，键盘可到达所有操作；不需要辅助功能授权。
- 性能验收：空闲不忙循环、不重叠检查，展开动画和状态更新不造成可感知卡顿。
- 每次改动后运行 `git diff --check`；签名、公证、发布和远程写入均不在本计划授权范围内。

## 约束与停止规则

- 不改变核心诊断逻辑，不引入遥测、历史采集、自动修复、节点切换、代理配置修改或日志上传。
- 2.0 只交付本地实现和验证；不得在 README、Release 或提交信息中声称 2.0 已发布。
- 当前构建仍可能无有效代码签名；继续使用 `CODE_SIGNING_ALLOWED=NO` 做本地/持续集成验证。签名、公证、登录项实机批准和公开发布需要另行授权。
- 若公开 API 无法在 macOS 13 上稳定提供几何信息，退化为顶部胶囊并保留诊断可用性；不以私有 API 补洞。
- 若浮窗遮挡、输入监听泄漏、VoiceOver 不可用、性能回归或任一安全边界无法验证，停止扩大功能，先修复或退回到顶部胶囊/现有面板。
