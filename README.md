# BrowserPet

Mac 桌宠找页工具。点击小猫或按 **Control + Option + Space**，搜索 Chrome、Safari、Edge 当前打开的页面，一键切回原标签页。

[下载 macOS 安装包](https://github.com/kudoushinichiYu/BrowserPet/releases/latest) · [版本说明](docs/releases/v0.3.2.md)

## 安装与使用

需要 **Apple Silicon（arm64）、macOS 13+**；Safari 助手需要 **Safari 18.4+**。打开 DMG，将 `BrowserPet.app` 拖到“应用程序”后启动。安装包无需 Python、Node 或 Xcode。

当前个人测试版为 **ad-hoc 签名，未使用 Developer ID、未经 Apple 公证**。首次下载可能被 macOS 阻止，或需要在系统设置中审查打开许可；组织策略不允许时可从源码构建。请勿关闭系统安全防护。

- 唤出后直接输入标题、网址或域名，上下选择，Enter 切换，Esc 收起。快捷键可在设置修改。
- 顶部可筛选浏览器；默认保留已连接的 Chrome 原组，未分组页面按用途归类，也可切换网站、窗口视图。
- 结果为紧凑单行。长标题用省略号，悬停后往返滚动；站点和窗口号悬停可看详情。同标题、同网址页面分别保留。
- 小猫支持拖动、记住位置、隐藏；右键打开搜索、设置或退出。隐藏后菜单栏爪印和快捷键仍可用。
- 开启系统“减少动态效果”时使用静态猫并停用标题滚动。登录启动可在设置注册，最终状态由 macOS 决定。

## 浏览器连接

### Chrome 与 Edge

运行浏览器后，首次搜索按 macOS 提示授予各自的自动化权限。基础搜索和切换无需扩展，不需要“允许 Apple Events 执行 JavaScript”、屏幕录制或辅助功能权限。应用不会为扫描启动尚未运行的浏览器。

支持同一浏览器实例的多个普通窗口及 Profile，独立 `user-data-dir` 或其他实例不保证覆盖。Chrome 已做本机运行验收；Edge 已实现且通过脚本契约测试，本次发布尚未安装 Edge 做实机验收。Firefox 尚未接入。

### Chrome 原有分组

1. 先将应用安装到“应用程序”，在面板点击“连接原分组”。按钮注册本用户的 Native Messaging 连接，并打开应用内的助手文件夹。
2. 在 Chrome 扩展管理页开启开发者模式，“加载已解压的扩展”，选择该文件夹。预期 ID 为 `cngkpacnncebfgaaldenbdlcnanpehca`。
3. 每个需要原组信息的 Chrome Profile 分别加载助手。连接后保留组名、颜色、成员及初始折叠状态。

助手仅申请 `tabGroups`、`nativeMessaging`，不申请页面访问或 `tabs` 权限，不读取标题、网址或正文，不注入网页、不访问外网。标题和网址由基础自动化适配器读取。主机固定来源，经本用户私有 Unix socket 传输；应用未运行时不自动启动应用。

移动应用后重新注册连接。卸载时移除 Chrome 扩展及本用户 `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/local.browserpet.groups.json`；不要删除其他主机配置。

未连接助手或未分组的页面，使用本机站点规则归入工作平台、论文与研究、代码与开发、AI 工具、文档与协作、其他网页。网站视图合并 arXiv 的 HTML/PDF 入口；不会将所有 PDF 猜作论文。Edge 的原标签组暂未同步。

### Safari 页面助手

Safari 通过配套助手取得稳定窗口和标签 ID，避免通过标题、URL 或下标猜测原页面。

1. 在面板点击“Safari 连接”，打开生成的本用户助手文件夹：`~/Library/Application Support/BrowserPet/SafariHelper`。
2. 在 Safari 设置开启网页开发者功能，在“开发者”选项中“添加临时扩展”，选择该文件夹，按系统提示完成认证。
3. 允许所需 HTTP/HTTPS 网站访问以提供标题和网址，**保持隐私浏览访问关闭**。面板显示连接后即可搜索、切换。

使用 Apple 的[临时 Safari Web Extension 方式](https://developer.apple.com/documentation/safariservices/running-your-safari-web-extension)。**退出 Safari 或 24 小时后需重新加载**；长期安装版尚需正式打包和签名。安全认证与受保护的安装操作应由用户在 Safari 中完成。

助手需要 `tabs`、`storage`、HTTP/HTTPS 访问权限，无内容脚本，不读网页正文、历史或书签。先筛选隐私标记明确为普通的窗口，再读取其标签；仅在父窗口明确普通且窗口 ID 一致时，兼容 Safari 省略冗余标签隐私字段的情况。不同 Profile、后台实例与标签 ID 隔离。

配对密钥在每台 Mac 的用户目录随机生成，不包含在 Release 安装包中。文件和助手配置仅限当前用户读取，**不要分享上述 BrowserPet 用户数据目录**。应用仅监听 `127.0.0.1:49731`，校验精确扩展来源、Host、Bearer 密钥、协议和请求大小，无通配 CORS、Cookie 或请求正文日志。临时助手每秒同步，断连 8 秒后清除失效页面；端口冲突或单一浏览器失败不影响其他来源。

## 刷新、定位与隐私

搜索不区分英文大小写，支持部分匹配及空格分隔的多词 AND，词可分别命中标题或网址；完整标题、标题匹配优先，同级优先当前窗口。

面板打开时读取，展开期间每 3 秒静默刷新。相同内容不重建列表，只更新实际变化的行；结构变化保留有效选择和可见滚动位置。后台刷新不插入加载提示行，避免周期性闪动。

选择后按原浏览器、会话、窗口与标签 ID 定位，恢复最小化并前置。Safari 还需原助手实例确认精确命令；标签关闭、实例过期或超时会报告失败，禁止用网址重开代替原页。Chrome 的脚本窗口 ID 不是 CGWindowID，跨 Space 或全屏后的可见性受 macOS 行为影响，不保证所有组合。

页面和分组数据只在内存，退出清空；无痕默认排除，不读取正文、书签或历史，不上传浏览记录。持久化仅包括界面偏好、随机 Profile ID、本机配对及连接配置。图标采用本地字母，避免请求外部 favicon 服务。分组只改变面板显示，不移动浏览器标签。

## 从源码构建

需要 macOS、Apple Silicon、Command Line Tools（Swift 5.9+）。测试另需 Node.js 和 Python 3；生成开发用 Safari 助手也使用 Python 3。

```sh
./scripts/build.sh
open build/BrowserPet.app
./scripts/test.sh
```

`Package.swift` 提供源码目标；完整应用、资源和签名请使用构建脚本。开发构建将本机配对复制到 `build/` 方便临时助手调试，**不可分享开发构建包**。现有开发配对迁移到用户目录时会保留原密钥。

公开分发请使用：

```sh
./scripts/package-dmg.sh
```

该命令构建无预置密钥的 Release 应用，生成 `dist/BrowserPet-<版本>-macOS-arm64.dmg` 和 SHA-256 校验文件，再验证镜像、挂载内容、签名、架构及个人路径/密钥未打入包。签名为 ad-hoc，不包含公证步骤。临时构建目录自动清理，产物与本地验收材料不提交到 Git。

## 验证与代码

[验证范围](docs/VALIDATION.md) 区分自动检查、已有本机验收和未验收场景。脚本失败立即返回非零；本机 socket 集成检查需允许绑定本机端口。2,000 条合成页面性能只代表内存匹配，不代表浏览器扫描速度。

- `Core.swift`：模型、匹配排序、原组/用途/网站/窗口分组。
- `ChromeAdapter.swift`、`Resources/chrome-*.js`：Chrome/Edge 的读取、精确切换和会话隔离。
- `GroupModel.swift`、`GroupBridge.swift`、`extensions/chrome-groups`：原组协议与 Native Messaging。
- `SafariAdapter.swift`、`SafariLoopback.swift`、`LocalSetup.swift`、`extensions/safari-tabs`：本机配对、普通窗口过滤与定位确认。
- `MultiBrowserAdapter.swift`：汇总、来源失败隔离和原浏览器路由。
- `SearchPanel.swift`、`HoverTitleView.swift`：紧凑列表、搜索交互、增量刷新与悬停标题。
- `PetView.swift`、`PetAtlas.swift`：7 种动画、16 方位注视、拖动及减动模式。
- `HotKey.swift`、`SettingsController.swift`、`AppDelegate.swift`：快捷键、登录项、菜单栏和生命周期。

猫图集由 Codex 内置 image gen 生成，[来源与提示词](Resources/pet-atlas-provenance.json)保留生成记录；具体底层模型未核实。原 PNG 不改动，使用逐猫边界、主体隔离及统一透明画布处理全部 69 帧。重算边界的 `scripts/map-pet-atlas.py` 另需 Pillow，正常构建不需要。
