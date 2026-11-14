# Antigravity 黑屏修复（自动检测代理）

![Version](https://img.shields.io/badge/version-2.0.0-blue)
![Platform](https://img.shields.io/badge/platform-Windows_10%20%7C%2011-0078D4)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

> 自动定位 Antigravity、检测可用本地代理，并统一桌面、开始菜单和登录回调的启动入口。
> **安装一次，以后照常点击原来的图标。** 适用于代理配置导致的黑屏、加载超时和部分登录失败问题。

**当前版本：`2.0.0`** · [快速开始](#快速开始) · [高级用法](#高级用法) · [常见问题](#常见问题) · [卸载与还原](#卸载与还原)

## 为什么会黑屏？

在部分版本和网络环境下，浏览器能通过系统代理访问 Google，Antigravity 后台却未正确使用同一代理。后台初始化或鉴权请求超时后，就可能出现：

- 窗口已经打开，内容却一直黑屏或空白；
- 长时间停在加载页面；
- 等待一段时间后，又回到登录界面。

本工具为新启动的 Antigravity 及其后台进程显式配置代理，同时让本机界面服务和登录回调保持直连。[相关 Windows 问题报告](https://discuss.ai.google.dev/t/windows-2-17-0-language-server-exe-ignores-system-proxy-during-startup-causing-infinite-loading-black-screen/184774)

> 黑屏也可能来自显卡驱动、应用版本、账号资格或服务故障。本工具处理的是**代理配置这一类原因**，不保证修复所有黑屏。

## 这个脚本做了什么？

1. **自动定位 Antigravity**  
   检查常见安装目录、正在运行的进程，以及卸载注册表中的 `DisplayIcon`／`InstallLocation`。也支持手动指定安装路径。

2. **每次启动自动检测可用代理**  
   从 Windows 系统代理、v2rayN 运行时配置、代理环境变量和常见端口中收集候选，先检查端口，再通过代理实测 Google HTTPS 连接；失败就继续下一个。

3. **让界面和后台使用同一代理**  
   为进程设置 `HTTP_PROXY / HTTPS_PROXY / ALL_PROXY`，配合 Electron 代理参数启动，并通过 `NO_PROXY` 等设置绕过本机连接。

4. **统一日常启动入口**  
   将匹配的桌面、开始菜单等快捷方式，以及 `antigravity://` 登录回调指向独立启动器，保留原来的参数、图标和工作目录。

5. **自动维护更新后的入口**  
   安装登录后运行的维护进程，每 **30 秒**检查一次，修复应用更新将匹配入口重置回原 EXE 的情况。

6. **备份原配置，支持卸载还原**  
   保存原快捷方式文件、注册表值及类型；重复安装不会覆盖最初的备份。卸载时保留用户另外修改过的设置。

## 快速开始

### 运行前提

- 已安装 Antigravity，使用 **Windows 10／11**。
- v2rayN、Clash 等本地代理客户端正在运行，节点可以访问 Google。
- 代理提供本机 **HTTP 或混合端口**。
- 安装时使用 Windows 自带的 **Windows PowerShell 5.1／.NET Framework**。

### 安装只需四步

1. 点击 GitHub 仓库的 **Code → Download ZIP**，或下载项目提供的源码包。
2. **完整解压**，保持目录内的文件在一起。
3. 双击 **`Install.cmd`**，按提示完成安装。
4. 保存工作，从托盘**完全退出 Antigravity 一次**，再点击原桌面或开始菜单图标。

以后只需：**代理客户端保持运行 → 正常点击 Antigravity 图标。**

安装器通常不需要管理员权限，也不会强制结束当前 Antigravity 进程。

### 安装在哪里？

默认目录：

```text
%LOCALAPPDATA%\AntigravityProxyLauncher
```

启动器独立于 Antigravity 安装目录，应用更新不会直接覆盖它。安装器会从 `Dispatcher.cs` 在本机编译小型调度程序，不依赖 VBScript 或第三方软件包。

## 代理客户端与端口

| 配置 | 支持方式 |
| --- | --- |
| v2rayN HTTP／混合入站 | 自动读取运行时配置并验证 |
| Windows 系统代理中的本机 HTTP 地址 | 自动读取并验证 |
| Clash 等客户端的常见 HTTP／混合端口 | 自动探测并验证 |
| 自定义 HTTP／混合端口 | 从系统代理／v2rayN 配置读取，或手动指定 |
| 纯 SOCKS、需要代理用户名密码、远程代理 | 当前不支持 |

内置候选端口：

```text
7890 / 7897 / 7899 / 7891 / 10809
10808 / 10811 / 1080 / 8888 / 2080
```

**端口没有写死为 10809。** 每次启动都会重新检测，系统代理或 v2rayN 配置还可以提供上述列表之外的端口。

## 接管哪些启动入口？

| 入口 | 行为 |
| --- | --- |
| 当前用户桌面、开始菜单快捷方式 | 匹配所选 Antigravity EXE 后改为启动器 |
| 当前用户启动文件夹 | 接管匹配的快捷方式 |
| 当前用户任务栏固定目录 | 更新匹配的快捷方式；Windows 缓存可能需要重新固定 |
| `antigravity://` 协议 | 接管已指向所选 EXE 的命令，保留登录回调参数 |
| 当前用户已有 Run／RunOnce 项 | 接管直接指向所选 EXE 的命令 |
| 入口维护进程 | 新增登录项，每 30 秒检查并修复匹配入口 |

安装器**不会额外开启 Antigravity 本体的开机启动**，只新增入口维护进程的登录项。

手工直接运行原 EXE、更新器自行重启、独立 CLI、第三方硬编码路径和其他 Windows 用户的入口不在接管范围内。维护检查之间也有约 30 秒的间隔；本工具不替换原 EXE，不做全局进程劫持。

## 高级用法

在解压后的项目目录打开 PowerShell。

### 安装与入口管理

```powershell
# 只预览将接管的入口，不安装
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Manage-Launcher.ps1 -Preview

# 指定 Antigravity 的安装路径
.\Install.cmd -AntigravityPath "D:\Apps\Antigravity\Antigravity.exe"

# 立即检查并修复已安装的入口
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Manage-Launcher.ps1 -Repair
```

同时安装 App 和 IDE 时，可通过完整路径选择 `Antigravity IDE.exe`。工具按所选 EXE 匹配入口。

### 启动与网络诊断

```powershell
# 预览启动配置：只检查本地端口，不访问 Google、不启动应用
.\Launch.cmd -DryRun

# 自动检测代理并检查更多 Google 服务，不启动应用
.\Launch.cmd -Diagnose -CheckNetwork

# 指定 HTTP／混合端口，直接启动
.\Launch.cmd -ProxyPort 10809

# 指定 v2rayN 的位置，自动读取其代理配置
.\Launch.cmd -V2rayNPath "D:\Tools\v2rayN\v2rayN.exe"
```

### 参数说明

| 脚本 | 参数 | 作用 |
| --- | --- | --- |
| `Install.cmd` | `-AntigravityPath <路径>` | 指定要接管的 Antigravity EXE |
| `Manage-Launcher.ps1` | `-Preview` | 预览安装计划 |
| `Manage-Launcher.ps1` | `-Repair` | 立即修复已安装的入口 |
| `Manage-Launcher.ps1` | `-Uninstall` | 卸载并还原原设置 |
| `Launch.cmd` | `-ProxyPort <端口>` | 本次启动手动指定代理端口 |
| `Launch.cmd` | `-ProxyHost <地址>` | 配合端口指定回环地址，如 `::1` |
| `Launch.cmd` | `-V2rayNPath <路径>` | 指定 v2rayN 目录或 EXE |
| `Launch.cmd` | `-AntigravityPath <路径>` | 本次启动指定 Antigravity EXE |
| `Launch.cmd` | `-DryRun` | 仅预览，使用 TCP 检查候选 |
| `Launch.cmd` | `-Diagnose` | 检测可用代理，不启动应用 |
| `Launch.cmd` | `-CheckNetwork` | 增加 Google 服务 HTTPS 检查 |

`-CheckNetwork` 单独使用时，检查后仍会尝试启动应用；**只想诊断时请同时使用 `-Diagnose`**。手动启动参数不会固定写入已安装启动器。

## 卸载与还原

双击安装目录中的 **`Uninstall.cmd`**，或在 PowerShell 中执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\AntigravityProxyLauncher\Manage-Launcher.ps1" -Uninstall
```

卸载会：

- 还原本工具仍在管理的快捷方式和注册表值；
- 移除新增的维护登录项，后台维护进程在下一次检查时退出；
- 保留源码和备份，方便检查；用户在安装后另外改过的入口会保留并报告。

**先卸载，再删除安装目录。** 直接删除目录会使快捷方式指向不存在的启动器。若安装中途修改入口失败，安装器会尝试使用备份还原。

## 常见问题

### 浏览器能上 Google，为什么还要这个工具？

浏览器和 Antigravity 后台不一定采用同一套代理设置。工具为新进程显式配置代理，处理后台未正确使用系统代理的情况。外部浏览器本身仍需要能够访问 Google。

### 需要开启 TUN 吗？

本工具通过 HTTP 代理启动，通常不要求为它单独开启 TUN。已有且运行正常的 TUN 可以保留。

### 安装后第一次打开还是黑屏？

先保存工作，**从托盘完全退出旧实例**再打开。新窗口或登录回调可能被转交给已运行的实例，旧进程不会因为新快捷方式而自动更换代理环境。

然后运行：

```powershell
.\Launch.cmd -Diagnose -CheckNetwork
```

若网络检查通过仍黑屏，继续排查显卡、驱动、应用版本和界面初始化问题。

### 更新 Antigravity 后还需要重跑安装吗？

维护进程会自动检查常见入口，更新后可以等待约 30 秒。如果安装位置变了，或要改为接管另一个 App／IDE，请重新运行 `Install.cmd`。

### 任务栏图标仍然打开原程序？

Windows 可能缓存固定入口。先取消固定，再从更新后的桌面／开始菜单入口重新固定。

### 为什么 HTTP 404 也算可达？

检查访问的是服务根路径或诊断路径，收到 404 也说明通过代理收到了 HTTPS 响应。**网络可达不等于登录成功**，也不能证明账号资格、模型调用或流式连接正常。

### 会删除聊天记录、清除账号或关闭安全软件吗？

不会。工具修改自己的运行目录、匹配的用户启动入口及维护登录项，不删除应用数据，不清除凭据，也不添加忽略证书或关闭 Chromium 沙箱的参数。

### 能在 macOS／Linux 上运行吗？

当前版本只支持 Windows。主脚本兼容 PowerShell 5.1／7，安装调度器时使用 Windows PowerShell 5.1。组织执行策略或应用控制策略仍可能限制运行；调度器未做代码签名。

## 日志与故障排查

日志位于安装目录：

| 文件 | 内容 |
| --- | --- |
| `last-launch.log` | 最近一次隐藏启动的输出 |
| `guard-error.log` | 维护进程出现错误时的记录 |
| `install-state.json`、`backup/` | 本机入口状态及原设置备份 |

| 启动退出码 | 含义 |
| --- | --- |
| 0 | 启动／转交成功，或所选诊断完成 |
| 1 | 参数、配置、应用路径或其他错误 |
| 3 | 没有找到通过检查的本机 HTTP／混合代理 |
| 4 | 额外的 HTTPS 连通性检查失败 |

工具不上传配置或日志。提交 Issue 时可提供系统、Antigravity、代理客户端版本及脱敏后的诊断输出；请勿公开订阅链接、节点配置或登录令牌。

<details>
<summary>技术原理与检测边界</summary>

启动器为进程树临时设置：

```text
HTTP_PROXY  = 检测到的本机 HTTP 代理
HTTPS_PROXY = 同上
ALL_PROXY   = 同上
NO_PROXY    = localhost,127.0.0.1,::1
```

同时传入 Electron 的 `--proxy-server` 和 `--proxy-bypass-list` 参数，确保界面请求与后台使用同一代理，本机服务保持直连。用户级、系统级代理环境变量及 Windows 系统代理不会被永久修改。

普通启动通过候选代理请求 `https://oauth2.googleapis.com/`，每个活跃候选设置 4 秒超时。HTTP 200—499（407 除外）作为传输可达依据，5xx、代理认证失败和连接错误会跳过。正常校验证书，不携带登录凭据、不读取响应正文。

`-CheckNetwork` 额外检查 `accounts.google.com`、`oauth2.googleapis.com` 和 `daily-cloudcode-pa.googleapis.com`，每个端点设置 10 秒请求超时。`-DryRun` 只检查 TCP，不能证明代理可以访问 Google。

调度器通过进程环境传递 JSON 参数，再进行 Windows 参数转义，保留登录 URI、中文、空格、引号和空参数，不把这些参数拼进可执行的 PowerShell 代码。

</details>

## 目录结构

```text
antigravity-v2rayn-launcher/
├── Install.cmd               # 双击安装
├── Uninstall.cmd             # 卸载还原
├── Launch.cmd                # 手动启动／诊断
├── Manage-Launcher.ps1       # 安装、入口维护与卸载
├── Start-Antigravity.ps1     # 代理检测与应用启动
├── AntigravityProxy.psm1     # 代理与进程环境处理
├── LauncherInstall.psm1      # 入口备份、接管与恢复
├── Dispatcher.cs             # 隐藏启动与参数转发
├── Build-Dispatcher.ps1      # 在本机编译调度器
├── tests/
│   ├── Run-Tests.ps1
│   └── Run-InstallTests.ps1
├── README.md
├── VALIDATION.md              # 实际验证记录
└── LICENSE
```

## 测试与开源

**32 个测试用例**已分别在 Windows PowerShell 5.1 和 PowerShell 7 上通过，累计执行 **64 次检查**。详见 [验证记录](VALIDATION.md)。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-InstallTests.ps1
pwsh.exe -NoProfile -File .\tests\Run-Tests.ps1
pwsh.exe -NoProfile -File .\tests\Run-InstallTests.ps1
```

测试使用临时目录、独立测试注册表键、本地端口和测试调度器，不修改真实 Antigravity 入口、不启动真实应用、不访问 Google。覆盖代理筛选、环境继承与恢复、参数转发、更新后入口修复和卸载还原。

发布源码时请保留 `LICENSE`，不要包含安装目录中的本机配置、备份、日志或编译产物，相关路径已列入 `.gitignore`。实际 UI、真实账号登录和模型调用仍需在目标电脑验证。

## 参考与致谢

- [Electron 官方代理参数文档](https://www.electronjs.org/docs/latest/api/command-line-switches)
- [v2rayN 官方 Wiki](https://github.com/2dust/v2rayN/wiki/Description-of-some-ui)
- 同类开源项目：[HGT158/antigravity-proxy-fix](https://github.com/HGT158/antigravity-proxy-fix)（MIT）

## License

[MIT](LICENSE)

本项目与 Google、Antigravity、v2rayN 官方无隶属或背书关系。
