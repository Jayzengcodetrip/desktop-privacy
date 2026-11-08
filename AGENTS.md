# 桌面文件隐身 — 项目说明（每次开工先读）

这是所有参与本项目的 Agent 共用的唯一项目说明书。开始前先读本文件和 `决策记录.md`。`CLAUDE.md`、`GEMINI.md` 只保留 `@AGENTS.md`。

## 1. 这是什么

独立的 macOS 菜单栏工具：默认单击菜单栏眼睛，隐藏点击时桌面上全部可见的顶层文件或文件夹，再点恢复显示及本次隐藏前的最新位置。原来的指定文件隐藏保留在右键菜单、控制面板和名单窗口；手动名单独立保存，可自由增删。每次隐藏重新记录位置，文件夹内部结构和内容必须得到保护。

这是不预置个人数据的通用版。同一个 Universal 2 App 包含 Apple Silicon 和 Intel 两种架构；最低编译目标 macOS 13。Windows 版尚未开发。

## 2. 正式位置与版本

| 对象 | 位置或标识 |
| --- | --- |
| 正式开发目录 | `~/Projects/DesktopPrivacy`，本文件所在目录 |
| 源码 | `Sources/` |
| 隔离测试 | `Tests/main.swift`、`scripts/test.sh` |
| 构建和打包 | `scripts/build.py` |
| 本机交付产物 | `dist/`，不进 git |
| 本机当前运行 App | `~/Documents/Codex/2026-10-29/new-chat/outputs/桌面隐身/桌面隐身.app`，外层旧文件名保留，包内已由用户明确要求替换为通用版 1.1.0 |
| 版本报告 | `版本报告/` |
| 接手和检查提示词 | `项目交接/` |
| 通用版 Bundle ID | `io.github.jayzengcodetrip.desktop-privacy`，不可随意更改 |
| 通用版用户数据 | `~/Library/Application Support/io.github.jayzengcodetrip.desktop-privacy/`，不属于源码 |
| 公开仓库 | https://github.com/Jayzengcodetrip/desktop-privacy |

当前构建版本：**1.1.1 / build 5**，版本权威值在 `scripts/build.py`。沿用 1.1.0 默认隐藏全部及指定文件功能，新增 DMG 分发。用户已明确授权本次同步 GitHub；原公开基线为 v1.0.1，提交 `1d1c51197567ef33d1f711223d6131cbbfc01a4e`。本机正在使用的 App 仍为上一轮安装的 1.1.0，本次打包不会自动替换运行中的 App。

旧源码位于 `~/Documents/Codex/2026-10-29/new-chat/work/desktop-privacy-public/`，旧交付位于该历史工作目录的 `outputs/桌面文件隐身/`。这些是保留的历史副本，后续开发以本项目为准，不双向同步。

原个人版的源码在同一历史工作目录的 `work/desktop-privacy/`，应用原在 `outputs/桌面隐身/`。2026-11-08 用户明确要求“直接替换旧版”后，已在原 App 路径换为通用版 1.1.0 并启动；旧 App 与两版数据的升级备份放在项目外 `~/Library/Application Support/DesktopPrivacy-UpgradeBackups/`。原个人版源码和 Application Support 数据仍保留原样，不迁入本仓库。旧 App 包内历史预置名单不能迁入新版；本次两边磁盘名单均为空，无需迁移。

## 3. 技术结构和代码地图

Swift + AppKit + Foundation + Darwin，无第三方运行时依赖。通过 Finder 自动化读取、核对和恢复图标位置；只给本次目标项目设置文件隐藏属性，不移动文件，也不切换 Finder 的全局桌面开关。

| 文件 | 职责 |
| --- | --- |
| `Sources/main.swift` | 启动菜单栏 App；`--smoke-test` 会初始化实际用户数据，不能误当成完全只读检查 |
| `Sources/AppConfiguration.swift` | 通用版名称、标识、当前用户桌面路径及独立数据目录；首次为空名单 |
| `Sources/Core.swift` | 全量/指定两种隐藏、文件身份校验、共用恢复状态机、原子恢复记录、文件锁及名单编辑 |
| `Sources/FinderLayout.swift` | Finder 布局、显示配置校验与位置恢复；处理 macOS 27 的 Finder 读取限制 |
| `Sources/AppUI.swift` | 菜单栏、主面板、名单管理、退出保护和版本展示 |
| `Tests/main.swift` | 合成文件及布局替身测试，不操作真实桌面 |
| `Tests/UI/main.swift`、`scripts/ui_preview.sh` | 使用临时合成桌面及布局替身的真实 AppKit 界面预览，不操作真实 Finder |
| `scripts/build.py` | 两种架构编译、合并、签名、DMG / 本地 ZIP 打包、旧产物清理 |
| `scripts/privacy_check.py` | 源码、App、ZIP 及只读挂载 DMG 内容的隐私检查 |
| `scripts/test_packaging.py` | 临时目录中的包内容扫描、快捷方式限制与最近两版清理检查 |
| `.github/workflows/macos.yml` | GitHub 上两个架构的原生隔离测试、通用构建和产物检查 |
| `docs/VERIFICATION.md` | 历史公开版验证证据及限制；新版本以对应版本报告为准 |

## 4. 合作规则

- 中文沟通，少用术语；先解释实际结果，再说必要的限制。
- 按用户指定范围改动；只有新需求和已记录决定冲突时，先问用户。
- 不把编译成功、合成测试通过、Rosetta 运行、界面查看或物理 Intel 实测混为一谈。
- 本机项目默认不推送远程；本次目录整理不是再次发布 GitHub 的授权。
- 不在项目说明、日志、截图或提交中加入真实隐藏名单、私人文件名、绝对用户名路径、证书或密钥。

## 5. 数据保护与行为约束

1. 不修改个人版源码、隐藏名单和恢复记录。通用版与个人版的数据目录独立。个人版 App 仅在 2026-11-08 用户明确要求后做过已备份的原位替换，不把这次授权扩展为未来任意修改原数据。
2. 不能把任何用户数据目录复制到源码、发行包或 Git。通用版也必须以空名单开始。
3. 只处理桌面顶层普通文件和文件夹，拒绝最终路径为符号链接的项目；不递归修改文件夹内容，不修改 Finder 的全局 `CreateDesktop` 开关。全量模式遇到不支持的可见项目或重复文件身份时，在任何修改前拒绝整次隐藏，不悄悄跳过。
4. 通过设备、inode、创建时间确认文件身份，不能仅凭文件名操作替换后的文件。
5. 每次隐藏前获取最新布局，先持久化恢复记录，再改隐藏标记。恢复失败保留记录，不擅自清除。
6. 只修改必要的隐藏属性，保留其他属性；不移动、改名文件，不重写桌面元数据文件来强制排序。
7. 仅支持手动排列（排序方式为“无”）；自动排序、贴紧网格、叠放或显示配置变化时安全拒绝，不替用户改变设置。
8. 隐藏期间其他图标被主动调整后，恢复不能强行覆盖用户的新调整。
9. 无账号、联网、遥测或上传。隐藏不等于加密，也不能隐藏文档窗口或通知。
10. 默认使用临时合成文件测试。真实 Finder 操作需要明确的测试范围；不得为了验证项目整理就试着隐藏用户真实文件。
11. “全部”指本次点击时的可见桌面文件和文件夹；排除点文件、原已隐藏项目，不处理磁盘/设备等虚拟桌面图标。隐藏期间新出现的文件不自动跟踪，下次隐藏再纳入。
12. 全量目标不写入手动名单，失效手动名单不阻挡全量操作。两种模式同一时刻只允许一个恢复会话，眼睛优先恢复该会话。新恢复记录使用 schema 2 并绑定桌面路径及身份；旧 schema 1 的指定名单记录仍可恢复。不要用旧版 App 处理新版未恢复记录。

## 6. 编译、验证与发版

需要 macOS、Python 3、Apple Command Line Tools 或 Xcode。以下命令在项目根目录运行：

```sh
bash scripts/test.sh
python3 scripts/test_packaging.py
python3 scripts/build.py
python3 scripts/privacy_check.py
codesign --verify --strict --all-architectures 'dist/桌面文件隐身.app'
```

- 测试脚本只在临时目录运行合成场景。涉及隐藏/恢复核心变化时再补相应失败路径测试和专用测试桌面实测。
- 版本只在 `scripts/build.py` 定义：每次交付增加版本及 build；App 从构建产生的 Info.plist 展示版本。DMG / ZIP 名称必须带版本。
- 本机产物在 `dist/`，不自动覆盖用户正在使用的 App，也不自动启动它。
- 成功构建后，仅清理 `dist/` 内本工具命名格式匹配的旧 DMG / ZIP 分发包及版本校验文件，保留最新和倒数第二版本；不删版本报告、Git 历史、备份、其他目录或其他工具的产物。历史工作目录的保留副本不纳入新项目构建清理。
- 公开安装附件只上传 DMG，内含 App、指向 `/Applications` 的快捷方式及中文说明。ZIP 可在本机保留，不再作为公开安装选项；GitHub 自动提供的源码归档需注明不是安装包。DMG 挂载审计仅允许根目录这个明确指向 `/Applications` 的快捷方式，不跟随它，其他链接仍拒绝。
- 源码 ZIP 只从已提交的 Git 文件生成，不能直接压缩整棵工作目录；文件名形如 `Desktop-Privacy-1.0.2-source.zip`。
- 私人审计词可由项目外文件传给隐私检查器，但不得复制进仓库。交接文档使用 `~/` 路径，不写真实用户名。
- 当前仅 ad-hoc 签名，未 Developer ID 签名、未 Apple 公证。安装说明不提供关闭系统安全检查的命令。
- GitHub 发布仅在用户明确要求时进行。届时核对远程基线、源码、发行下载、实际解压结果和校验值，不能把草稿视为已发布。

## 7. Git 规则

- `main` 保留公开 v1.0.1 的原有 3 次提交历史，本机变更在其后提交。
- `origin` 保留原 GitHub 地址作为来源记录；默认只提交本机，不 push。
- 现有本机 1.1.0 提交的作者元数据含设备身份，不能直接推送本机 main 历史。公开发布使用从远程基线建立的 `codex/public-v*` 副本，以公开 GitHub 身份提交同一最终源码树；保留本机历史，不强推或改写原公开历史。GitHub 连接不支持发行附件且网页上传受限时，沿用独立 `codex/release-files-v*` 分支存放 DMG，以固定提交提供直接下载，再通过网页发布 Release；不从浏览器提取凭据。
- 提交说明用中文；发版提交以版本号开头。
- `dist/`、`.app`、ZIP、用户数据、日志、临时测试与编译缓存不进 Git。
- 开工先检查状态，不能覆盖其他 Agent 或用户的未提交改动。

## 8. 收工流程

需求完成后主动：追加决策记录，更新本说明，写含“问题 / 改了什么 / 验证 / 没有验证”的版本报告，核对产物仅保留最近两版，完成本地 Git 提交，然后用大白话报告结果和未完成项。

## 9. 已知坑点

- 旧 Git 验证副本原本处于 detached HEAD，旧本地 main 停在 v1.0.0；迁移已从实际 v1.0.1 提交重建 main。不要误用旧分支降级。
- macOS 27 用 AppleScript 直接读取桌面 icon view options 可能报 -1728；已有 CFPreferences 读取方案不能随意删除。
- Finder 显示隐藏文件时，隐藏项目仍可能可见；录制前仍应查看实际画面。
- 当前构建工具链可能对 Intel 的 Swift compatibility packs 输出警告；要看实际编译、签名和架构检查，不把警告直接等同失败。
- DMG 打包使用 `hdiutil create -srcowners any -anyowners`，明确保持源卷所有权设置不变；不要改成 `-srcowners off`，后者可能要求修改源卷设置并弹出管理员授权。
- `.app` 是应用包，可以从桌面运行；放进“应用程序”是推荐的整理方式。微信分发应使用 ZIP 等单文件。
- 项目设置的“Available sources”是云端资料区；本机编辑源码应添加下面“Local folders”中的整个项目目录。两者不是同一项配置。
