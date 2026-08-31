# ProxySentry 2.0 刘海浮窗设计规格

状态：2.0.0 实现规格
日期：2026-08-30

## 目标

把当前本地 v0.1.0 的菜单栏弹出面板改为 macOS 原生刘海浮窗，同时保留现有诊断核心、证据分层和只读权限边界。

用户可见结果：

- 不显示菜单栏图标，也不显示 Dock 图标；应用只在需要时显示浮窗。
- 有刘海的屏幕将状态收纳在刘海区域，悬停时展开为终端风格胶囊。
- 网络状态变化时立即复检但不自动展开；黄、红或灰状态连续至少 3 分钟时短暂展开一次。
- 离开浮窗、外部点击或按 Escape 后收起；收起不停止诊断、不清除证据。
- 无刘海的外接屏或普通屏幕退化为顶部胶囊，不伪造刘海或遮挡系统菜单栏。

现有诊断仍负责区分基础网络、系统代理、Clash 内核和当前节点。Clash 私有接口继续是可失效的增强层，不能阻塞通用诊断。

## 成功标准

- 收纳态用符号和短标签表达当前五种诊断状态；展开态保留 `base / traffic / proxy / clash` 四行终端矩阵。
- `traffic ACTIVE` 只表示已经观察到非直连 Clash 流量；`WAIT` 表示没有证据，不表示失败。
- 有刘海、无刘海、外接屏、多屏、负坐标、Dock/菜单栏区域和全屏 Space 均不会出现屏外、遮挡、裁切或重叠。
- 浅色、深色、长中文、异常溢出和持续故障展开均保持可读；悬停和收起不造成输入焦点丢失或卡死。
- VoiceOver（macOS 屏幕阅读器）可以读出状态、矩阵和操作，键盘可以到达全部操作；不需要辅助功能权限。外部点击只通过公开的只读鼠标事件监视器观察，不拦截或修改其他应用输入。
- 空闲时没有忙循环或重叠诊断；短时网络变化不触发展开；持续故障只展开一次并约 5 秒后收起，鼠标仍在面板内时不强制收起。
- 不增加遥测、历史采集、原始连接/节点/订阅展示、自动修复、节点切换、系统代理修改或第三方依赖。

## 交互状态

| 状态 | 触发 | 用户可见行为 | 退出 |
| --- | --- | --- | --- |
| 收纳 | 无 hover、无持续故障提醒 | 顶部胶囊保持最小宽度，仅显示状态符号和短标签 | 鼠标悬停或持续故障达到阈值 |
| hover 展开 | 鼠标进入浮窗的本地 tracking area | 展开终端风格面板，显示四行矩阵、主结论和最多两条异常证据 | 鼠标离开、外部点击或 Escape |
| 持续故障展开 | 黄、红或灰状态连续至少 3 分钟 | 展开约 5 秒且同一次故障只提醒一次 | 计时结束、用户离开或外部点击；恢复正常后重置提醒资格 |
| 60 秒检查 | 稳定状态定时器 | 后台更新模型；仅在持续故障达到阈值时触发一次展开 | 下一次检查或用户 hover |
| 外部点击/Escape | 浮窗外点击或 Escape | 立即收起，不取消正在进行的诊断 | 下一次 hover 或新的持续故障提醒 |
| 无法定位几何 | 屏幕信息缺失、尺寸无效或无刘海 | 使用 `visibleFrame` 顶部胶囊 fallback，诊断继续可用 | 获得有效屏幕信息后重新布局 |

## 公开 API 与几何降级

只使用公开 AppKit API（Application Programming Interface，应用程序编程接口；系统允许应用调用的接口）：

- [`NSScreen.safeAreaInsets`](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets)、[`auxiliaryTopLeftArea`](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea-uglc) 和 [`auxiliaryTopRightArea`](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytoprightarea-gr2n)：识别刘海两侧的可用区域。
- [`NSScreen.visibleFrame`](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe)：无刘海或安全区数据不可用时的顶部区域边界。
- [`NSPanel`](https://developer.apple.com/documentation/appkit/nspanel) 和公开的 [`NSWindow.CollectionBehavior`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications)：实现浮窗层级、Space 和全屏行为。

几何计算应是接收屏幕矩形、可用矩形、刘海左右矩形、胶囊尺寸和边距的纯函数；AppKit 屏幕对象只在外层读取。布局规则如下：

1. 使用鼠标当前所在屏幕；无法定位鼠标屏幕时优先内置刘海屏，再退化到主屏或第一个可见屏幕。
2. 有有效刘海左右区域时，窗口中心与物理刘海对齐，所有可读和可交互内容位于摄像头遮挡区下方。
3. 无刘海、外接屏或数据无效时，使用 `visibleFrame` 的顶部胶囊布局。
4. 多屏和负坐标使用屏幕自身坐标，不假设原点在主屏左下角；内容过宽时限制在可用矩形内。
5. 只使用公开 API；禁止 SkyLight、Core Graphics Services（CGS，核心图形服务；macOS 私有窗口管理接口）或其他私有 API。不得使用会拦截输入的全局事件 tap 或申请辅助功能权限；外部点击可用公开的只读鼠标事件监视器观察。

`boring.notch` 和 [Atoll](https://github.com/rutmehta/Atoll) 只作为刘海收纳、展开动画和顶部胶囊的产品形态参考，不是 API 依据、运行时依赖、合作方或兼容性保证；官方行为以 Apple 文档为准。

## 文件所有权与验证

实现阶段主代理只负责 `ProxySentryApp.swift`、`StatusPopoverView.swift`、对应应用/视觉测试和必要的 `project.pbxproj` 接线；诊断模型、探针、Clash 读取和通知语义保持不变。测试优先复用现有 XCTest（Apple 的单元测试框架）target，不引入新的测试框架或第三方快照依赖。

最小自动验证：

- 纯几何测试覆盖刘海、无刘海、无效数据、多屏负坐标、过宽内容和 visible frame 边界。
- 自动测试确认测试宿主不创建全局浮窗，并覆盖持续故障三分钟后仅提醒一次及恢复后重置；hover、离开、外部点击和 Escape 由下述实机验收覆盖。
- 收纳态渲染测试覆盖五种状态；展开态渲染覆盖 `ACTIVE`/`WAIT`/`PASS`/`N/A`、长文本和异常溢出。
- 浅色、深色和异常溢出渲染测试；固定时间，检查 PNG（Portable Network Graphics，便携式网络图形）可生成且布局没有越界。当前视觉测试没有像素基线，最终外观仍需实机检查。
- Debug 全量测试、Release 无签名构建、arm64 与 x86_64 通用产物和 `git diff --check`。

实机验收：刘海 MacBook、无刘海外接屏、多屏、全屏 Space、浅色/深色、VoiceOver、键盘操作、鼠标离开、外部点击、Escape、短时网络变化不展开和至少一个 60 秒稳定窗口。

## 约束与停止规则

- 核心诊断逻辑不变；浮窗只呈现已存在的状态和证据，不重新解释探针结果。
- 不增加遥测、自动修复、配置写入、节点切换、历史记录、原始日志或敏感信息展示。
- 不增加第三方依赖；不使用私有 API；不申请辅助功能、网络扩展或管理员权限。
- 当前签名、公证、登录项实机批准和公开发布仍未授权；只完成本地构建与验证，不在文档或 Release 中声称 2.0 已发布。
- 若公开 API 在 macOS 13 上无法稳定取得刘海几何，退化为顶部胶囊；若浮窗出现遮挡、焦点问题、事件监听泄漏、VoiceOver 不可用、性能回归或安全边界无法验证，停止扩大功能并修复或退回现有面板。
