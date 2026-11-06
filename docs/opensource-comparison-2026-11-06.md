# PasteLite 与 GitHub 剪贴板管理工具的功能结构对照

调研日期：2026-11-06（Asia/Shanghai）

本地基线：PasteLite 0.3.2

方法：核对 GitHub 已发布版本的 README、发布说明及关键源码。没有逐个安装，也没有做运行速度、内存占用或交互质量排名。

## 主要结论

PasteLite 已覆盖自动记录、类型筛选、内容与来源搜索、分类预览、单项复制/粘贴和基础隐私管理。竞品进一步扩展的功能主要集中在：

1. **常用内容管理：** 收藏、分组、命名、备注、可编辑片段。
2. **内容检索与处理：** 图片 OCR、模糊/正则搜索、来源过滤、格式转换。
3. **多项复用与自动化：** 多选、合并、Paste Stack、脚本或外部工具接口。

下一版以“收藏库与常用片段”为主线的建议仍成立。对比后，应提高本地 OCR 和收藏备份的后续优先级；多项粘贴作为独立流程开发，避免一次功能版本同时承担分组、编辑、OCR 和队列的全部复杂度。

## 调研对象与版本

| 项目 | 核对的发布版本 | 平台 | 许可证 |
| --- | --- | --- | --- |
| [Maccy](https://github.com/p0deje/Maccy/releases/tag/2.8.0) | 2.8.0，2026-10-26 | macOS；该版本要求 14+ | MIT |
| [Clipy](https://github.com/Clipy/Clipy/releases/tag/1.4.1) | 1.4.1，2026-10-30 UTC | macOS；该版本要求 13+ | MIT |
| [CopyQ](https://github.com/hluk/CopyQ/releases/tag/v17.0.0) | 17.0.0，2026-10-06 | macOS、Windows、Linux | GPL-3.0 |
| [EcoPaste](https://github.com/EcoPasteHub/EcoPaste/releases/tag/v1.1.0) | 1.1.0，2026-07-22 | 当前版本文档列出 macOS、Windows | Apache-2.0 |
| [PasteBar](https://github.com/PasteBar/PasteBarApp/releases/tag/v0.7.0) | 0.7.0，2025-06-25 | macOS、Windows | CC BY-NC，含有限商用例外 |
| [Paste It](https://github.com/yipeng-git/paste-it/releases/tag/mac-v0.2.9) | Mac 0.2.9，2026-09-28 | macOS 14+ | MIT |

日期来自 GitHub 发布记录；Clipy 特别标出 UTC，避免其上海日期跨日造成歧义。Clipy 当前开发分支已要求 macOS 14，而 1.4.1 发布版仍支持 13，本表采用发布版。PasteBar 是带使用限制的源码公开项目，许可证与表中的 MIT、Apache、GPL 不同；具体条款见其 [CC-LICENSE](https://github.com/PasteBar/PasteBarApp/blob/v0.7.0/CC-LICENSE)。

## 按功能层理解这些工具

| 功能层 | 包含的能力 | PasteLite 0.3.2 的状态 |
| --- | --- | --- |
| 采集与历史 | 记录格式、来源、去重、历史容量和生命周期 | 文本、代码、链接、颜色、图片、文件；本地持久化与容量设置 |
| 检索与预览 | 内容搜索、来源/类型过滤、OCR、预览和元信息 | 内容及来源名称搜索、类型筛选、多类型预览；尚无 OCR |
| 收藏与片段 | 置顶、分组、命名、备注、手动创建和编辑 | 单层置顶；尚无用户分组、命名或编辑 |
| 粘贴与处理 | 直接粘贴、纯文本、多选、合并、队列和文本转换 | 单项复制/粘贴、纯文本转换与键盘操作 |
| 数据与隐私 | 排除规则、敏感内容、备份、同步、外部接口 | 排除应用、暂停、机密遮罩和固定到期、清空退出；尚无应用内备份和外部接口 |

现有类型筛选按内容格式分类；收藏分组按用户用途分类。两者可以同时使用，例如在“项目 A”中筛选链接，或在“提示词”中搜索用户设置的名称。

## 六个项目的主要功能结构

### Maccy：围绕快速调用扩展

```text
Maccy
├─ 历史：轻量浮窗、键盘导航、复制与直接粘贴
├─ 检索：普通、模糊、正则和混合搜索；图片 OCR
├─ Pins：置顶、固定调用键、内容别名、文本编辑、拖拽排序
├─ 多项复用：多选历史、Paste Stack 顺序粘贴
└─ 偏好：存储、外观、应用和剪贴板类型排除
```

Maccy 当前版本已经超出早期的简单历史列表。其组织结构仍围绕单层 Pins；多选内容能进入 Paste Stack。OCR 在后台把识别结果保存为图片条目的可搜索标题。

对 PasteLite 有价值的参考：呼出后立即搜索、固定收藏调用键、简单编辑入口，以及在保持轻量列表的同时扩展 OCR 和多项粘贴。

依据：[2.8.0 发布说明](https://github.com/p0deje/Maccy/releases/tag/2.8.0)、[搜索模式](https://github.com/p0deje/Maccy/blob/2.8.0/Maccy/Search.swift)、[内容编辑](https://github.com/p0deje/Maccy/blob/2.8.0/Maccy/Views/ItemEditorView.swift)、[OCR](https://github.com/p0deje/Maccy/blob/2.8.0/Maccy/Models/HistoryItem.swift)、[Paste Stack](https://github.com/p0deje/Maccy/blob/2.8.0/Maccy/Observables/History.swift)。

### Clipy：历史菜单与片段库并行

```text
Clipy
├─ 主菜单：历史、片段、设置
├─ 历史：最近复制内容、图片/颜色缩略图、容量与清理
├─ 片段：文件夹 → 有名称的文本片段
├─ 片段编辑器：新建、改名、编辑、启停、拖拽排序
└─ 调用与迁移：独立片段入口、文件夹快捷键、XML 导入导出
```

Clipy 把临时复制历史和长期维护的片段分开，是“收藏库与常用片段”最直接的结构参考。片段具备名称和正文，文件夹具备独立快捷键，编辑器支持导入导出。

1.4.1 源码还接入了后台 OCR 并保存 `ocrText`，但本次未确认这些结果对应的用户检索或文字提取入口，因此不把它与 Maccy、Paste It 的可搜索图片功能等同列出。

依据：[发布版 README](https://github.com/Clipy/Clipy/blob/1.4.1/README.md)、[片段编辑器](https://github.com/Clipy/Clipy/blob/1.4.1/Clipy/Sources/Snippets/CPYSnippetsEditorWindowController.swift)、[采集中的 OCR 接入](https://github.com/Clipy/Clipy/blob/1.4.1/Clipy/Sources/Services/ClipService.swift)。

### CopyQ：多标签页与可编程操作

```text
CopyQ
├─ 条目库：多个标签页，每页保存一组内容
├─ 条目管理：新建、编辑、排序、拖拽、多选、备注和标签
├─ 查找与粘贴：即时过滤、主窗口/托盘/全局快捷键
├─ 命令：手动动作、快捷键动作、剪贴板变化触发、CLI 和脚本
└─ 扩展与数据：插件、置顶、加密导出、目录同步、导入导出
```

CopyQ 将“保存内容”和“对内容执行操作”做成可扩展系统。它的标签页相当于多个内容容器，备注与标签提供额外的组织方式；文本转换及流程自动化可以通过命令和脚本实现。

对 PasteLite 有价值的参考：选中内容的统一操作入口、可搜索备注、多选管理和数据导出。完整脚本系统需要单独定义产品范围。

依据：[发布版功能说明](https://github.com/hluk/CopyQ/blob/v17.0.0/README.md)、[基础使用](https://github.com/hluk/CopyQ/blob/v17.0.0/docs/basic-usage.rst)、[键盘与多选操作](https://github.com/hluk/CopyQ/blob/v17.0.0/docs/keyboard.rst)、[备份与导入导出](https://github.com/hluk/CopyQ/blob/v17.0.0/docs/backup.rst)。目录同步通过插件实现，实际跨设备行为还取决于共享目录或外部同步工具。

### EcoPaste：历史、收藏与分组结合

```text
EcoPaste
├─ 历史：文本/HTML/RTF、图片、文件与文件夹
├─ 导航：全部、收藏、类型、自定义分组
├─ 检索：正文与备注全文搜索、来源应用过滤
├─ 条目动作：粘贴、纯文本复制、备注、置顶、收藏、拖出
└─ 数据与保护：保留策略、敏感模式识别、普通/加密备份
```

EcoPaste 在同一套历史内容上提供收藏、置顶、备注和用户分组，结构比单层 Pins 更完整。发布版使用 SQLite FTS5 搜索正文和备注，提供明确的应用来源过滤，以及包含加密备份包的导入导出。

本次确认的编辑入口是备注编辑；发布版文档没有列出手动文本片段编辑或 OCR，不据此推断旧版本能力。自定义分组删除时，条目回到未分组状态，适合参考其管理语义。

依据：[1.1.0 中文 README](https://github.com/EcoPasteHub/EcoPaste/blob/v1.1.0/README.zh-CN.md)、[分组导航](https://github.com/EcoPasteHub/EcoPaste/blob/v1.1.0/src/pages/Clipboard/components/Group.tsx)、[分组数据与删除规则](https://github.com/EcoPasteHub/EcoPaste/blob/v1.1.0/src-tauri/src/db/groups.rs)、[备注编辑](https://github.com/EcoPasteHub/EcoPaste/blob/v1.1.0/src/pages/Clipboard/components/NoteModal.tsx)。

### PasteBar：内容工作台与转换工具

```text
PasteBar
├─ 历史与 Quick Paste：检索最近复制内容、快速调用
├─ 保存内容：Collection → Tab → Board → Clip
├─ 内容编辑：名称、备注、代码、图片、表单和模板
├─ 处理能力：文本整理、编码解码、JSON/CSV/Markdown 等转换
├─ 外部数据：Web 请求、API 提取、网页抓取
└─ 数据与保护：PIN 保护集合、自定义数据目录、备份恢复
```

PasteBar 的组织层级最深，更接近维护常用内容的工作台。0.7.0 提供 30 多种特殊复制/粘贴操作，包括大小写、空白和行处理、编码解码、结构化格式转换；模板、表单和外部数据能力进一步扩展条目的用途。

对 PasteLite 有价值的参考：从历史保存为有名称的内容、收藏管理与快速粘贴采用不同入口、按需执行少量文本操作。完整 Collection/Tab/Board 层级会增加管理成本，适合在更明确的工作台需求下采用。

自定义目录可以交给云盘或共享盘管理；本次没有确认内建账号同步、冲突合并或端到端同步服务。PIN 保护集合也只按已确认的功能描述记录，不推断其所有数据均被加密。

依据：[0.7.0 README](https://github.com/PasteBar/PasteBarApp/blob/v0.7.0/README.md)、[发布功能](https://github.com/PasteBar/PasteBarApp/blob/v0.7.0/WHATS_NEW_0.7.0.md)、[组织层级](https://github.com/PasteBar/PasteBarApp/blob/v0.7.0/migrations/2023-08-05-153510_create_collections/up.sql)、[转换操作](https://github.com/PasteBar/PasteBarApp/blob/v0.7.0/packages/pastebar-app-ui/src/locales/lang/zhCN/specialCopyPaste.yaml)。

### Paste It：视觉历史、OCR 与粘贴队列

```text
Paste It
├─ 历史时间线：卡片、类型过滤、搜索、快捷操作
├─ 预览：文本编辑、图片 OCR 查看/重跑、链接预览
├─ 保存内容：Pinned 与自定义文件夹
├─ 多项复用：多选直接粘贴、Paste Stack 复制队列
└─ 设置与接口：隐私、保留策略、更新、可选本地 MCP
```

Paste It 的扩展围绕现有复制内容展开：图片能按识别出的文字搜索，文本可以在预览中编辑，多个条目可以按顺序粘贴。Paste Stack 支持先复制多项，再在目标应用中逐次按 Cmd-V 使用队列。0.2.9 文档将用户自建文件夹限制为三个。

可选 MCP 默认关闭，提供本地历史的读取和搜索工具；文档没有开放主历史、采集和设置的修改接口。它服务外部代理调用，本次不将其归为应用内 AI 改写功能。

对 PasteLite 有价值的参考：可搜索 OCR、复制多项后顺序粘贴的队列流程，以及区分“删除历史”“移出收藏”和“永久删除”的数据语义。

依据：[0.2.9 README](https://github.com/yipeng-git/paste-it/blob/mac-v0.2.9/README.md)、[0.2.9 发布说明](https://github.com/yipeng-git/paste-it/releases/tag/mac-v0.2.9)、[MCP 范围](https://github.com/yipeng-git/paste-it/blob/mac-v0.2.9/docs/mcp.md)。

## 功能差异速查

“未确认”表示本次发布版资料和定向源码核对没有建立证据，不表示通过第三方脚本绝对无法实现。

| 项目 | 常用内容结构 | 创建/编辑 | 搜索扩展 | 复用扩展 | 迁移与恢复 |
| --- | --- | --- | --- | --- | --- |
| PasteLite 0.3.2 | 单层置顶 | 无手动创建/编辑入口 | 内容、来源名称、类型 | 单项、纯文本 | 本地库；无应用内导出入口 |
| Maccy 2.8.0 | Pins、固定调用键 | 别名与文本编辑 | OCR、模糊、正则 | 多选与 Paste Stack | 本次未确认应用内备份入口 |
| Clipy 1.4.1 | 文件夹 → 文本片段 | 新建、命名、编辑、排序 | 以菜单导航为主；OCR 检索入口未确认 | 文件夹快捷入口、修饰键动作 | 片段 XML 导入导出 |
| CopyQ 17.0.0 | 标签页、标签、备注 | 新建与编辑条目、外部编辑器 | 内容过滤；命令可扩展 | 多选、命令、CLI、脚本 | 标签页/配置/命令导入导出 |
| EcoPaste 1.1.0 | 收藏、置顶、自定义分组、备注 | 备注编辑 | 正文/备注全文、来源、类型 | 自定义动作、拖出条目 | 普通与加密备份包 |
| PasteBar 0.7.0 | Collection/Tab/Board/Clip、菜单 | 自建内容、模板、表单 | 内容与备注全局搜索 | 格式转换、文本操作、外部数据 | 数据库与图片备份、自定义目录 |
| Paste It 0.2.9 | Pinned、自建文件夹 | 已复制文本的预览编辑 | 图片 OCR、类型、搜索 | 多选、Paste Stack、可选读取 MCP | 本地存储；本次未确认备份入口 |

## 对 PasteLite 规划的具体影响

| 优先级 | 模块 | 建议范围与参考 |
| --- | --- | --- |
| 下一次功能版本 | 收藏库与常用片段 | 参考 Clipy 的片段语义、EcoPaste 的一级分组、Maccy 的别名和调用；完成分组、命名、文本副本编辑与快速粘贴 |
| 收藏库稳定后的首批补充 | 收藏导入导出/备份 | 优先支持可移植的收藏与文本片段；完整数据库备份再明确图片和文件引用的恢复范围 |
| 下一项检索增强 | 本地 OCR 与筛选 | 图片后台识别、识别文字预览/复制/搜索；补明确的来源过滤；长历史下测量搜索响应 |
| 独立的效率版本 | 多选、合并、Paste Stack | 先完成选中多项及合并复制，再决定队列的顺序、取消、应用切换与失败处理 |
| 有明确需求再立项 | 模板变量、脚本、MCP、同步 | 按真实使用场景选择；分别定义接口、权限、数据和配置范围 |

收藏、OCR 和 Paste Stack 对应不同的收益：收藏减少反复寻找常用内容，OCR 让截图能通过文字找回，多项粘贴减少反复切换应用。缺少实际使用频率时，竞品功能覆盖只能支撑方向判断，不能证明本项目用户的需求排序。

这份对照为 [0.4.0 开发计划](plan-0.4.0.md) 提供外部功能依据；具体版本范围、开发批次和验收以开发计划为准。

## 本地基线

- [当前功能](../README.md)
- [版本记录](../CHANGELOG.md)
- [0.3.2 验收状态](acceptance-0.3.2.md)
- 搜索、筛选与选择：`Sources/PasteLite/App/AppState.swift`
- 历史、预览与操作：`Sources/PasteLite/Views/HistoryPanelView.swift`、`Sources/PasteLite/Views/DetailView.swift`
- 置顶、历史容量与载荷：`Sources/PasteLite/Stores/HistoryStore.swift`、`Sources/PasteLite/Stores/HistoryRepository.swift`
