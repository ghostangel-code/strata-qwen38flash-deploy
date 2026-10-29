# 一键部署 Strata + Qwen3.8-Flash

Windows 下的 Strata 本地大模型一键部署脚本：**检测硬件 → 选型 → 自动下载 → 启动服务 → 生成一键启动入口**。

一个 `deploy-strata.ps1` 覆盖从裸机到可用的全过程，全程不需要管理员权限、不写注册表、不建计划任务。

支持三种量化：**Coder IQ1_M（编程）**、**IQ3_XXS（通用）**、**UD-IQ4_XS（高质量）**。

---

## 一、前置要求

| 项目 | 要求 | 脚本判定 |
|---|---|---|
| 系统 | Windows 10 / 11，PowerShell 5.1 及以上 | — |
| 内存 | 64 GB | 上报 ≥ 63.0 GiB（真 64 GB 内存条在 Windows 上报约 63.90 GiB） |
| 显存 | NVIDIA 24 GB | 最大可用卡 ≥ 23.5 GiB（驱动保留区会让上报略低） |
| 系统盘 | `%LOCALAPPDATA%` 所在盘 ≥ 8 GB | 引擎组件固定装在这里，不受 `--data-dir` 影响 |
| 数据盘 | 见下方「磁盘门槛」 | 默认脚本所在分区，不够会自动改选其他固定盘 |
| 网络 | 能访问 ModelScope / hf-mirror / GitHub | GitHub 直连不通时自动切 `gh-proxy.com` |

**磁盘门槛** = 权重 + 7.3 GB（图片编码器 0.85 + MTP 草稿层 6.45） + 1.4 GB（专家 pack） + 1.8 GB（框架） + 24 GB（缓存预留，可用 `-ReserveGB` 调整）：

| 模型 | 磁盘门槛 |
|---|---|
| Coder IQ1_M | 92.9 GB |
| IQ3_XXS | 110.3 GB |
| UD-IQ4_XS | 128.2 GB（64 GB 内存时脚本会自动把预留提到 32 GB → 136.2 GB） |

已存在的文件（含未下完的 `.part`）会从需求里扣除，不会重复计算。

---

## 二、快速开始

```powershell
# 1. 下载脚本
# 2. 在脚本所在目录运行（交互式：检测完成后会让你选 coder / iq3 / iq4）
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy-strata.ps1
```

也可以先预览、不下载不启动：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy-strata.ps1 -DryRun
```

想双击运行？在同目录自己建一个 `deploy.bat`（纯 ASCII + CRLF）：

```bat
@echo off
chcp 936 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy-strata.ps1" %*
pause
```

### 常用命令

```powershell
# 非交互：直接指定量化
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy-strata.ps1 -Model coder

# 只用「脚本所在磁盘」，不检索也不改选其他盘
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy-strata.ps1 -LocalOnly -Model coder

# 指定数据目录（强制，不再自动改选分区）
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy-strata.ps1 -DataDir "E:\Strata-data" -Model iq3

# 顶掉已在运行的服务，换成所选模型
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy-strata.ps1 -Model iq4 -ForceRestart

# 部署完顺带拉起 FRP（可选）
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy-strata.ps1 -Model coder -FrpExe "D:\frp\frpc.exe" -FrpIni "D:\frp\frpc.ini" -PublicUrl "http://1.2.3.4:25560/v1"
```

### 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Model` | 交互选择 | `iq3` / `iq4` / `coder`（也可写 `iq1_m`、`ud-iq4_xs`、`iq3_xxs`） |
| `-DataDir` | 自动 | 数据目录；指定后不再自动改选分区 |
| `-LocalOnly` | 关 | 只用脚本所在磁盘，不检索/不改选其他盘 |
| `-Port` | 8080 | 服务端口 |
| `-Context` | `256k` | 上下文（256K 为模型原生长度，不触发 YaRN） |
| `-ReserveGB` | 24 | 磁盘缓存预留（下载临时文件、pack 构建、页面文件） |
| `-Source` | `auto` | `auto` / `modelscope` / `huggingface`（下载渠道） |
| `-Vision` | `cpu` | 图片编码器位置：`cpu` / `gpu` / `off` |
| `-KVResident` | 32768 | 常驻显存的 KV 窗口（256K + 24 GB 显存的必需值） |
| `-Feed` | 自动 | 引擎签名 feed 目录（离线安装用） |
| `-FrpExe` / `-FrpIni` / `-PublicUrl` | 无 | 可选：把 FRP 启动写进生成的 bat 并打印公网地址 |
| `-DryRun` | 关 | 只预览：不下载、不启动、不写 bat、不建快捷方式、不建目录 |
| `-NoShortcut` | 关 | 不在桌面创建快捷方式 |
| `-ForceRestart` | 关 | 允许顶掉已在运行的服务 |
| `-MinRamGB` / `-MinVramGB` | 64 / 24 | 硬件门槛（留给更严格的机器） |

### 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 2 | 前置检测失败（内存/显存/磁盘不足，或 `-LocalOnly` 冲突） |
| 3 | 模型选择失败 / 用户取消 / 需要先停服务 |
| 4 | 框架或引擎安装失败 |
| 5 | 模型下载未完成 / 完整性校验失败 |
| 6 | 启动失败 / 健康检查超时 |
| 7 | bat 或桌面快捷方式生成失败 |

---

## 三、脚本做了什么（六个阶段）

1. **硬件与系统盘检测**：内存、逐卡显存、`%LOCALAPPDATA%` 所在盘剩余空间。任一不达标直接退出，**不下载任何文件**。
2. **模型选择**：每项三行列出 `权重体积 → 能力范围 → 本机预期 tok/s`，等你选。
3. **数据目录与磁盘**：优先复用已安装目录（从 `%LOCALAPPDATA%\Strata\install\strata-*.json` 反推）；不够则按剩余空间降序改选其他固定盘并新建 `<盘>:\Strata-data`（纯 ASCII 路径）；并用 `strata launch --plan --output json` 拿到真实待下载量。
4. **框架与引擎**：已装则跳过；未装则下载（GitHub 不通时走 `gh-proxy.com`，引擎走本地签名 feed，均做 SHA-256 / 字节数校验）。
5. **模型下载与完整性确认**：分片字节数 + `.done` 标记 + `mmproj` + `mtp` + `packs` 全部齐全才算下完；可中断续传。
6. **启动与产物**：以实测参数启动（`--kv int8 --set kv-resident=32768 --set vram-reserve-mib=1408 --vision cpu --access lan`），轮询 `/health`，打印接入信息，生成 `start-strata-<模型>.cmd` 并在桌面建同名快捷方式。

---

## 四、三个版本的差别

> 数据来自同一台机器实测：**RTX 3090 24 GB + 64 GB DDR4-2133 ECC + 256K 上下文 + kv int8 + kv-resident 32768 + vision cpu + MTP**。换硬件后速度仅作参考。

### 4.1 总览

| | **Coder IQ1_M** | **IQ3_XXS** | **UD-IQ4_XS** |
|---|---|---|---|
| 命令 | `--family coder --model iq1_m` | `--family qwen --model iq3_xxs` | `--family unsloth --model UD-IQ4_XS` |
| 权重下载 | 58.4 GB | 75.8 GB | 93.7 GB（三分片） |
| 专家体积 | 23.4 GB | 42.9 GB | 59.5 GB |
| 全驻留内存 | 约 32 GB | 约 60 GB | 约 80 GB |
| 磁盘门槛（预留 24 GB） | **92.9 GB** | **110.3 GB** | **128.2 GB** |
| 解码（400 token，MTP 开） | 47 tok/s | **67 tok/s** | 未实测，按带宽估 30–45 tok/s |
| 208K 长提示预填 | **2,301 tok/s（90 s）** | 1,725 tok/s（120 s） | 未实测（全驻留约需 128 GB） |
| 单图识别（CPU 编码） | 4.8 s | 3.5–5 s | 未实测 |
| MTP 草稿接受率 | 63% | 66% | — |
| 64 GB 内存余量 | 宽松（提交 81.1/95.9 GB） | 贴顶（提交 96.1/98.2 GB，余约 2 GB） | 部分专家读 SSD，更紧 |
| 1M 上下文 | 理论上可跑 | 需 128 GB | 需 128 GB |
| 质量参考 | SWE-bench 达完整模型 91%（作者数据） | top-1 一致率 84.5% | top-1 一致率 **88.9%**（最高） |

### 4.2 能力范围

**Coder IQ1_M —— 编程专精**
- 512 专家只保留代码 / 工具 / 视觉常用的 256 个，按 IQ3_S 格式存；代码修改、补丁生成、读大仓库最强
- 专家少一半，**预填比 IQ3_XXS 快约 33%**，显存常驻比例 53%（vs 32%）
- 代价是解码慢约 29%，通用中文长文弱于 IQ3_XXS
- 64 GB 上唯一还有余量去试 1M 上下文的版本

**IQ3_XXS —— 通用均衡**
- 24,576 专家全保留，3-bit i-quant；通用问答、中文长文、纯文本生成质量最好，**短对话解码最快（67 tok/s）**
- 缺点：64 GB 上 256K 内存贴顶（提交 96.1/98.2 GB），同时开别的程序容易换页

**UD-IQ4_XS —— 质量优先**
- ~4-bit Unsloth Dynamic（IQ3_S 的 gate/up + IQ4_NL 的 downs），质量介于 IQ3_S 与 UD-Q4_K_XL，top-1 一致率 88.9% 明显高于 IQ3_XXS 的 84.5%
- 59.5 GB 专家在 64 GB 机器上**只能部分驻留，其余从 SSD 读** → 解码明显变慢；全驻留建议 80 GB 以上内存
- 想发挥它最好配 128 GB 内存

### 4.3 选哪个

| 你的场景 | 选这个 |
|---|---|
| 写代码、改仓库、需要长上下文预填 | **Coder IQ1_M** |
| 中文长文、通用问答、短对话要快 | **IQ3_XXS** |
| 追求最高质量 / 内存更宽裕 | **UD-IQ4_XS** |
| 只有 64 GB，但想要 1M 上下文 | **Coder IQ1_M** |
| 内存贴顶、还同时开 IDE 和浏览器 | **Coder IQ1_M**（余量约 15 GB） |
| 磁盘吃紧（可用 < 110 GB） | **Coder IQ1_M**（92.9 GB） |

---

## 五、注意事项

### 5.1 环境与权限

- 不需要管理员权限；但要让**局域网**访问，需在 Windows 防火墙放行 8080（脚本用 `--access lan` 绑 0.0.0.0 并生成 API Key）。
- 脚本以 **UTF-8 with BOM** 保存（否则 PowerShell 5.1 中文会乱码）；生成的 `start-strata-*.cmd` 用 **GBK(cp936) + CRLF**（cmd 的 ANSI 代码页要求），所以里面不要出现中文绝对路径。
- 只支持 Windows + PowerShell 5.1 及以上，不使用 PowerShell 7 专有语法。

### 5.2 磁盘与目录

- 默认**复用已安装的数据目录**：只要 `%LOCALAPPDATA%\Strata\install\strata-*.json` 里记着旧的 `D:\...\Strata-data`，即使脚本放到别的盘跑，数据仍落在旧目录。
- 只有本机**从未装过**时，才会用「脚本所在分区」新建 `<盘>:\Strata-data`。当前盘不够会自动改选其他固定盘（会打印改选理由与各盘对照表）。
- `-LocalOnly` 表示「只用脚本所在磁盘」：
  - 空间不足 → 直接报「空间不足，无法安装」，**不提示也不改选其他盘**；
  - 该盘有完整模型 → 复用启动；
  - 该盘没有、本机也没装过 → 自动下载；
  - 该盘没有、但**已装在别的目录** → Strata 不会把同一模型重复下载到另一个目录；脚本会给出 `strata models move <目标目录>` 迁移命令并退出。想真重下，先 `strata launch --stop`，再移走 `install\strata-<tag>.json` 与 `launch\<tag>-<ctx>.json` 后重跑（会多占 60–95 GB 下载）。
- 引擎组件、Terminal、`launch` 配置固定在 `%LOCALAPPDATA%\Strata`（约 1 GB），**不受 `-DataDir` 影响**；所以脚本单独检查系统盘 ≥ 8 GB。

### 5.3 下载

- IQ3_XXS 默认先走 **ModelScope**（实测 29–57 MB/s）；一旦校验失败（仓库版本与 Strata 固定的 revision 不一致）自动改用 **hf-mirror** 重试一次。
- Coder 与 UD-IQ4_XS 直接走 **hf-mirror**，并发固定 4 路（`STRATA_DL_CONNECTIONS=4`）——16 路会被限流（HTTP 429）。
- 下载可续传：中断后直接重跑脚本，`.part` 不会被清理。
- 每个文件都有固定 SHA-256，不符会删除并中止；Coder 仓库有新旧两个版本（`5348543e` 与 `bba88856`），**不要混用**，混用会导致专家索引错位。

### 5.4 启动与运行

- 256K + 24 GB 显存时必须用 `--kv-resident 32768` 与 `--vram-reserve-mib 1408`：不加前者专家缓存只剩 916 槽，不加后者显存余量低于 1024 MiB 会触发告警（#2065）并让解码跌到个位数。
- `--vision cpu` 是因为 24 GB 卡跑 256K 已没有余量给 GPU 图片编码器；可用 `-Vision gpu` 覆盖。
- 首次启动要加载模型，约 1–2 分钟；健康检查最多等 **20 分钟**，超时会打印 `launch.log` 尾部并退出码 6（此时不会生成 bat / 快捷方式）。
- 端口 8080 被别的模型占用时，脚本会提示，需 `-ForceRestart` 或先 `strata launch --stop`。
- **关闭窗口不会停掉服务**：停止请执行 `strata launch --stop`（脚本会把这条命令打印出来）。
- `max_tokens` 小于约 1024 时思考内容会占满输出、正文为空，客户端侧要给足输出空间。

### 5.5 产物

- `start-strata-<模型>.cmd`：写在脚本所在目录；先 `strata launch --status`，已在运行就跳过启动，否则用固定参数启动，最后打印本机 / 局域网地址、模型名、API Key 与停止命令。
- 桌面快捷方式：`Strata <模型名>.lnk`，指向上面那个 cmd；同名会先删再建，不会出现 `(2)` 之类的重复项。
- 每次运行都会写日志 `deploy-<yyyyMMdd-HHmmss>.log` 到脚本所在目录。

### 5.6 与版本绑定的常量

脚本里的 Terminal 0.1.53 / 引擎 0.1.52 / 各分片字节数 / 引擎包 620,430,878 字节，都是按 **Strata 0.2.7** 核对过的。升级 Strata 后若完整性校验报字节数不符，请同步更新脚本里的 `Get-ModelTable` 与 `$ENGINE_TAR_BYTES`。

---

## 六、常见问题

**Q：提示「物理内存不足（需要 64 GB，实测 63.90 GiB）」，但我就是 64 GB？**
A：阈值是「标称减 1 GB」。若确实 64 GB 仍被拦，说明内存被 BIOS 占用较多或混插容量，可用 `-MinRamGB 48` 放宽（不建议跑 256K）。

**Q：在 E 盘运行，为什么模型还是下到 D 盘？**
A：脚本优先复用已安装目录。要强制换盘，用 `strata models move E:\Strata-data`（官方搬迁，复制+校验后删旧副本）；或在全新机器上首次部署。

**Q：下载到一半断了怎么办？**
A：直接重跑脚本，从 `.part` 续传。

**Q：`-ReserveGB 300` 为什么报空间不足？**
A：门槛 = 权重 + 7.3 + 1.4 + 1.8 + 预留，正常用 24 即可；这项只是留余量用的。

**Q：服务起来了，Trae / 其他客户端怎么接？**
A：OpenAI 兼容 `http://<ip>:8080/v1`；Anthropic 兼容根地址 `http://<ip>:8080`（不带 `/v1`）；上下文填 262144；需要图片就保留 `vision cpu`；思考强度参数名 `reasoning_effort`（none / low / medium / high）。

---

## 七、许可

脚本按现状提供（AS IS）。模型权重与 Strata 框架的许可遵循各自上游仓库（`ISTA-DASLab` / `unsloth` / `Niko1221/Strata`）。