# v1.0.1 验证记录

记录日期：2026-10-30。以下把构建、合成测试和真实 Finder 操作分开记录。

## v1.0.1 命名更新

应用名称统一为“桌面文件隐身”，没有业务逻辑变化。Bundle ID `io.github.jayzengcodetrip.desktop-privacy` 和本地数据目录保持不变。

| 本轮检查 | 实际结果 |
| --- | --- |
| v1.0.1 两架构构建与应用命名 | 通过：同包 `arm64` + `x86_64`；App 与窗口名均为“桌面文件隐身” |
| 最终应用与 ZIP 内容、版本及签名检查 | 通过：ZIP 内为“桌面文件隐身.app”，版本 1.0.1 / build 2；签名完整，两架构初始化通过 |
| v1.0.1 发行包 SHA-256 | `95b5b1141403898470379e6ceb2f3f8701253e6addb359433ba2315def4fe0f2` |

以下 35 项测试以及构建、启动记录来自 **v1.0.0**，不是 v1.0.1 已重新执行的结果。本轮构建和包检查结果见上表；本轮自动测试结果以对应提交的 GitHub Actions 记录为准。

## v1.0.0 已完成的验证

| 检查 | 实际结果 |
| --- | --- |
| 同一应用两架构 | `lipo -archs` 返回 `x86_64 arm64`；只分发一份 Universal 2 安装包 |
| 最低编译目标 | 两个 Mach-O slice 的 `LC_BUILD_VERSION` 均为 macOS 13.0 |
| Bundle ID | `io.github.jayzengcodetrip.desktop-privacy` |
| 签名完整性 | `codesign --verify --strict --all-architectures` 通过；ad-hoc，未公证 |
| Apple Silicon 原生核心测试 | macOS 27.0 / Swift 6.4，35 项通过，0 失败 |
| x86_64 核心测试 | 同一台 Apple Silicon Mac 上通过 Rosetta 运行，35 项通过，0 失败 |
| 两架构启动检查 | 对应用分别以 arm64 / x86_64 执行 `--smoke-test`，均初始化成功、名单为 0、未改桌面文件 |
| Apple Silicon 界面启动 | 主窗口显示空名单及可用的“添加桌面文件…”按钮 |
| 私人数据审计 | 源码、应用与 ZIP 检查通过；私人核对词表留在仓库外，不随项目分发 |
| 旧版本隔离 | 旧应用和旧数据的文件内容、大小、inode、修改时间与发布工作开始前一致 |

构建机的 Swift 6.4 工具链在 x86_64 链接时提示某个兼容静态库仅包含 ARM slice；最终链接成功，x86_64 启动及全部合成核心测试通过。最低目标不等于已在 macOS 13 实机验证。

## v1.0.0 合成测试覆盖

`bash scripts/test.sh` 在当前主机架构编译并运行测试。全部文件均创建于唯一临时目录，使用布局替身；不访问真实桌面或 Finder。35 项覆盖：

- 每次隐藏重新捕获位置，恢复至该次位置；名单外图标与用户主动移动受到保护。
- 只改目标隐藏属性，文件夹结构、文件内容及其他属性保留。
- 添加、移除、去重、拒绝非桌面顶层项目和符号链接，名单可持久化。
- 文件改名、移走、替换；操作中断、写入失败与重启后恢复。
- 自动排序、显示配置变化和“显示隐藏文件”模式的安全拒绝。
- 首次空名单、不同模拟用户之间独立、已有公开版状态重载、不导入旧应用数据。

这些测试包含真实 BSD 文件隐藏属性操作，但不证明 Finder 实际图标坐标或权限流程已在所有系统上通过。

## GitHub 自动化

仓库配置 `macos-15`（arm64）和 `macos-15-intel`（x86_64）两个 runner，分别原生执行合成测试并构建 Universal 2 应用。每个 job 首先核对 `uname -m`。

[查看本仓库 Actions 的实际结果](https://github.com/Jayzengcodetrip/desktop-privacy/actions)。只有具体 job 成功才代表对应环境的合成测试通过；不能把配置存在或 Rosetta 通过当成 Intel 原生通过。

## 尚未覆盖

- Intel Mac 真实桌面上的完整隐藏、恢复、位置核对和录屏回放。
- 公开版在 macOS 13 至 26 各个系统上的真实 Finder 流程。
- 干净 Mac 下载后 Gatekeeper 首次打开，以及 Finder/桌面权限允许和拒绝的完整流程。
- iCloud Desktop 切换、外接显示器变更和同步冲突的真实系统行为。

v1.0.0 验证时为避免影响已有工作环境，没有用真实私人文件重跑公开版隐藏操作。正式录制前，请用合成桌面文件在自己的系统上做一次短录屏检查。

## 复核命令

```sh
bash scripts/test.sh
python3 scripts/build.py
python3 scripts/privacy_check.py
xcrun lipo -archs dist/桌面文件隐身.app/Contents/MacOS/DesktopPrivacy
codesign --verify --strict --all-architectures dist/桌面文件隐身.app
```

发行 ZIP 的 SHA-256 见相同 Release 下的 `SHA256SUMS.txt`。构建机临时路径、真实用户文件名、原版名单和恢复快照均不写入此记录。
