# PasteLite 0.3.2 开发验收

- 验收日期：2026-11-06（Asia/Shanghai）
- 验收对象：基于 `9c03f19`（0.3.1）的 review 修复与 0.3.2 封版改动。
- 对照材料：`CHANGELOG-review-fixes.md` 与此前 review 报告。
- 初次结论：暂不通过，补充验收复现 1 个 P1 和 3 个 P2 问题。
- **当前结论：四项返修通过自动复验。封版 Debug 112 个测试、8 个套件；Release 111 个测试、7 个套件全部通过，均启用完整严格并发检查与 warnings-as-errors。** 版本信息已统一为 0.3.2 / build 32；下文列出的实机验收仍待后续完成。

## 返修复验结果

| 问题 | 修复与复验证据 |
| --- | --- |
| 应用切换监听 | 工作区通知中心注册/移除；主队列回调同步设置切换标记。往返切换测试在复制后切回并立即轮询，不添加延时；排除内容被跳过，下一次稳定来源内容正常记录。 |
| Undo | 失败保留载荷；Undo 与错误并排显示；删除成功不显示状态消息。通过 SQLite trigger 令恢复失败，再移除 trigger 重试，原始数据完整恢复；成功后旧错误清理。 |
| 强调色 | 从精确 RGB 值计算白色和 0.05 灰度前景的实际对比度；选中行文字、胶囊计数与主按钮提示不再衰减。实际 SwiftUI/NSColor 色值测试全部通过，对比度范围为 4.64–9.94:1。 |
| 筛选选择 | 列表展示期间仅搜索/筛选条件变化时重置首项。真实 SwiftUI hosting view 的搜索、类型筛选双路径测试覆盖新增保留选中 ID、删除选择相邻项、条件变化及重新展示时重置首项。 |

正式测试集已补充：

- `DesignBehaviorTests.allAccentForegroundsMeetSmallTextContrast`
- `RegressionTests.failedUndoRetainsPayloadAndCanRetryAfterStorageRecovers`
- `ReviewFixTests.filteredSelectionSurvivesCaptureAndDeletion`（搜索、类型筛选两个用例）
- 强化已有 `roundTripAppSwitchIsDetectedAndSkipped`：移除 50 毫秒等待，验证通知与紧接着的轮询顺序。

本次验证使用独立数据目录、偏好设置及构建目录：

- 全量测试：**111 个测试、8 个套件通过**。
- 标准 Release 构建：**通过**。
- 下文保留初次失败的分析和复现证据，便于对照。

封版阶段还修正了源应用图标缓存、链接预览元数据交接、可控测试时钟的隔离方式，以及 Release 测试对 Debug fixture 的引用。新增预览快照测试，确认原元数据修改不会影响 UI 副本，且图片载荷保留。预览导出套件仅参与 Debug 编译，因此两种配置的测试数相差一个。

SQLite 的四处事务与迁移统一在 `HistoryRepository` actor 内直接执行 BEGIN/COMMIT/ROLLBACK，不再通过回调捕获私有数据库连接。native SwiftPM 验证覆盖事务提交、回滚和并发历史行为。

双架构 Release 安装包已完成挂载、签名、版本、最低系统版本、归档内容与 SHA-256 检查；从两张 DMG 复制的应用均通过隔离启动，Intel 包通过 Rosetta 运行。正式包更新暂存与安装成功/回滚测试通过；隔离 Debug 应用的重复退出与历史清理验证通过。安装包校验和见 `docs/releases/0.3.2.md`。

## 初次验收发现（已返修）

### P1：应用切换监听使用了错误的通知中心，仍可能保存排除应用的内容

位置：`Sources/PasteLite/Services/ClipboardMonitor.swift:78-84`、`:100-103`。

`NSWorkspace.didActivateApplicationNotification` 由 `NSWorkspace.shared.notificationCenter` 发送，当前却注册到了 `NotificationCenter.default`，停止监听时也从普通通知中心移除。

复现场景：前一次轮询在 Editor；用户切到被排除的 Private 应用复制内容，然后在下一次轮询前切回 Editor。两次轮询的 bundle ID 相同，而应用激活通知没有被当前监听器接收，`sourceChanged` 为 false。Private 内容最终被记录并标记为 Editor。

验收测试在工作区通知中心投递两次激活通知，使用独立剪贴板复现了内容被保存。现有测试仅修改一次来源值，没有覆盖切走再切回，也没有调用 `start()` 验证通知监听。

返修要求：从工作区通知中心注册、移除监听；覆盖 A → 排除应用 → A 的往返切换，并确认通知处理与轮询顺序。该项属于隐私承诺，应作为完成验收的前提。

### P2：Undo 恢复失败会丢失重试所需的唯一载荷

位置：`Sources/PasteLite/Views/HistoryPanelController.swift:206-208`。

恢复失败后无条件调用 `discardUndo()`，会把 `deletedItem` 清空。此时原数据库记录已经删除，而恢复事务也未成功，之后即使存储故障消失，用户也无法再次撤销。

验收通过 SQLite trigger 注入恢复失败：错误消息确实出现，但 `deletedItem` 同时变为 nil，重试所需数据丢失。

另有相关回归：`HistoryPanelView.swift:175-179` 让所有状态消息优先于 Undo，而删除成功仍显示默认 3 秒的 “Removed from history.”；Undo 仅保留 5 秒，所以删除后的前 3 秒看不到 Undo 按钮。搜索框保持编辑焦点时，新的 Cmd-Z 分发也不会触发历史撤销。

返修要求：错误显示应独立于是否保留撤销载荷；失败后允许重试。区分错误与成功状态，删除成功后立即显示 Undo，避免成功提示压缩撤销操作窗口。

### P2：强调色只修复了 Yellow，其余七色仍使用低对比度白字

位置：`Sources/PasteLite/Views/PasteLiteTheme.swift:54-58`。

`relativeLuminance > 0.4` 才选择深色前景；现有颜色只有 Yellow 达到该阈值。因此变更记录中 “Yellow/Green/Orange 会返回黑色前景” 与实际实现不符。

使用 `NSColor` 解析实际 SwiftUI 色值，再按相对亮度计算的结果：

| 背景 | 实际前景 | 对比度 |
| --- | --- | --- |
| Blue | 白色 | 3.93:1 |
| Purple | 白色 | 4.20:1 |
| Pink | 白色 | 3.59:1 |
| Red | 白色 | 3.65:1 |
| Orange | 白色 | 2.53:1 |
| Yellow | 0.1 灰度深色 | 8.93:1 |
| Green | 白色 | 2.77:1 |
| Graphite | 白色 | 3.43:1 |

返修要求：比较实际候选前景与背景的对比度，并验证最终小字至少达到 4.5:1；不要仅替换一个未经验证的亮度阈值。还需验证选中行次要文字的 0.9 透明度、胶囊计数的 0.65 透明度。变更记录声称次要文字不再降透明度，当前源码仍有 `.opacity(0.9)`。

### P2：筛选中的列表发生任何数据更新都会把选择重置到首行

位置：`Sources/PasteLite/Views/HistoryPanelView.swift:69-70`、`:235`。

`normalize()` 根据“目前是否有搜索或筛选”决定 `resetIndex`，没有根据“本次是否改变了搜索或筛选”决定。只要当前不是 All，或搜索文本非空，`historyStore.items` 的每次变动都会强制选择首项。

验收以真实 `HistoryPanelController` / SwiftUI hosting view 打开 Text 筛选，选择第三项，再捕获一条新记录：原选择被改为首项。删除筛选结果中的中间项时，也无法保持相邻选择。

返修要求：搜索条件或筛选值发生变化时重置到第一项；数据重排和新增时保留有效的选中 ID；选中项被删除时才按旧位置选择相邻项。

## 初次验证结果

在独立临时源码快照、独立数据目录、独立偏好设置和独立构建目录中验证：

| 检查 | 结果 |
| --- | --- |
| 原有全量 Debug 测试 | 8 个套件、107 个测试全部通过 |
| 标准 Release 构建 | 通过 |
| 额外完整严格并发检查，warnings-as-errors | 未通过：`DesignSystem.swift:40` 的静态 `SourceAppIcon.cache` 不满足并发安全检查；该文件未在本轮修复中改动 |
| 额外验收测试 | 4 个测试均复现问题；其中对比度测试报告 7 个颜色断言失败 |
| 正式工作区业务代码 | 验收过程中未修改 |

已确认：独立 `expiresAt` 的数据库/内存路径、旧库迁移与最近使用后的持久化回归通过；Tab、文本选区 Cmd-C、AppKit NSButton Return 的分发分支测试通过；生产到期遮罩逻辑已使用独立期限；暂停横幅与复制失败重新显示面板的代码路径已加入。

上述分支测试不能替代真实 SwiftUI 控件焦点导航、实际复制选区、VoiceOver 和跨应用粘贴验收。

## 版本和待验收范围

- 封版阶段已将应用、打包脚本和 CI 的默认版本统一为 **0.3.2 / build 32**。
- 变更记录中已列为后续批次的性能、VoiceOver、双 Settings 窗口、小屏和文本缩放、默认快捷键冲突，本轮未完成实机验收。
- 原 review 中的 Used/Pasted 文案、成功反馈/HUD、Actions 打开链接后关闭、无目标时主按钮文案、HTML-only 输入等事项，不能视为本轮已修复。
- 未在 macOS 12 或物理 Intel 机器上运行；未执行真实跨应用粘贴和完整 VoiceOver 流程。

## 回归复现

初次验收的四个独立复现场景已转为正式回归测试。封版时使用独立数据目录、偏好设置和构建目录运行；本地日志与开发工具记录不随源码发布。

```sh
review_directory="$(mktemp -d)"
PASTELITE_DATA_DIRECTORY="$review_directory/data" \
PASTELITE_PREFERENCES_SUITE=PasteLite.ReleaseVerification \
SWIFT_TEST_SCRATCH_PATH="$review_directory/build" \
./script/run_checks.sh --no-parallel -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```
