# PasteLite Review Fixes — 2026-11-06

## 变更概览

- **源码文件修改：** 13 个（含封版版本信息及并发检查修正）
- **测试文件修改：** 5 个
- **文档更新：** 6 个（含本变更记录、验收报告及发布说明）
- **新增回归测试：** 11 个（Debug：101 → 112）
- **全量测试：** Debug 8 个套件、112 个测试；Release 7 个套件、111 个测试全部通过，均开启完整严格并发检查并将警告视为错误
- **验收返修：** P1 通知中心、P2 Undo 载荷、P2 对比度、P2 选择重置

---

## 批次一：隐私与键盘（高优先级）

### 1. 隐藏内容固定 24 小时期限

**问题：** `recordUse` 刷新 `copiedAt` 导致隐藏内容反复续期，违背"24 小时后删除"承诺。

**方案：** 引入独立 `expiresAt`，与 `copiedAt` 解耦。

**改动文件：**

| 文件 | 变更 |
|------|------|
| `Sources/PasteLite/Models/ClipboardItem.swift` | 新增 `expiresAt: Date?`，初始化器自动设置隐藏内容为 `copiedAt + 86400`；`isExpired` 基于 `expiresAt` |
| `Sources/PasteLite/Stores/HistoryRepository.swift` | SQLite schema v3 新增 `expires_at` 列；旧数据回填 `copied_at + 86400`；`insert`/`fetchRecentItems` 读写新列；`expireSensitive` 使用 `COALESCE(expires_at, copied_at + 86400)` |
| `Sources/PasteLite/Support/Database.swift` | 新增 `columnOptionalDouble` 支持可空 REAL 列 |
| `Sources/PasteLite/Services/ClipboardMonitor.swift` | 捕获隐藏内容时设置 `expiresAt` |
| `Sources/PasteLite/Services/ConcealedRevealModel.swift` | 到期遮罩计时使用注入式 `waitUntilExpiry` |

**回归测试：** `DesignBehaviorTests.concealedUseDoesNotExtendItsFixedExpiry`（数据库/内存双路径）

---

### 2. 排除应用来源判断竞态

**问题：** 轮询时读取前台应用，若复制后迅速切换应用，可能把排除应用的内容错误归属或保存。

**方案：** 来源不稳定时跳过该次记录（保守策略：宁可漏记，不冒险保存）。

**改动文件：**

| 文件 | 变更 |
|------|------|
| `Sources/PasteLite/Services/ClipboardMonitor.swift` | 从工作区通知中心监听应用激活，在主队列回调中同步标记切换；每次轮询比较 bundle ID，来源变化时跳过记录 |

**回归测试：** `DesignBehaviorTests.clipboardChangeDuringSourceSwitchIsNotCaptured`、`roundTripAppSwitchIsDetectedAndSkipped`（通知后立即轮询，随后验证稳定来源可以正常记录）

**已知取舍：** 用户复制后 0.5 秒内切走再切回，该次复制会被丢弃。这是隐私优先的保守策略。

---

### 3. 键盘事件分发修复

**问题：** Tab 被筛选快捷键占用；Cmd-C 覆盖文本选区复制；Return 在按钮焦点时误触发历史粘贴。

**改动文件：**

| 文件 | 变更 |
|------|------|
| `Sources/PasteLite/Views/HistoryPanelController.swift` | Tab/Shift-Tab 走系统焦点遍历；Cmd-C 在非空文本选区时放行；Cmd-Z 在文本编辑时放行；Return 在 NSButton/NSSegmentedControl 焦点时走原生激活 |
| `Sources/PasteLite/Views/HistoryPanelView.swift` | 筛选提示从"⇥ switch type"改为"↑↓ navigate" |
| `docs/design-redesign.md` | 键盘行为文档同步更新 |

**回归测试：** `RegressionTests.tabUsesNativeFocusNavigationInsteadOfCyclingFilters`、`commandCWithSelectedTextUsesNativeEventHandling`、`returnActivatesFocusedButtonInsteadOfHistoryAction`、`returnInSearchStillDispatchesHistoryAction`

---

### 4. 测试计时稳定性修复

**问题：** `revealingContentStopsAtItsExpiry` 使用真实 `Task.sleep(2.1s)` 与到期 `Task.sleep(2.0s)` 竞速，间歇性失败。

**方案：** `ConcealedRevealModel` 支持注入 `waitUntilExpiry`，测试改用可控时钟。

**改动文件：**

| 文件 | 变更 |
|------|------|
| `Sources/PasteLite/Services/ConcealedRevealModel.swift` | 新增 `ExpiryWait` 类型和 `init(waitUntilExpiry:)` |
| `Tests/PasteLiteTests/ReleaseReviewTests.swift` | 测试使用 actor 隔离的可控时钟与 continuation 握手，不再依赖真实时间或跨线程共享可变值 |

---

## 批次二：反馈与体验（中优先级）

### 5. 错误反馈优先级

**问题：** Undo 状态遮挡页脚错误；菜单栏复制失败无反馈。

**改动文件：**

| 文件 | 变更 |
|------|------|
| `Sources/PasteLite/Views/HistoryPanelView.swift` | Undo 始终可见，错误消息并排显示 |
| `Sources/PasteLite/Views/HistoryPanelController.swift` | Undo 失败保留载荷、显示错误；删除和恢复成功清理旧状态；菜单栏复制失败时重新打开面板 |

**回归测试：** `RegressionTests.failedUndoRetainsPayloadAndCanRetryAfterStorageRecovers`，覆盖删除成功无状态遮挡、SQLite 故障导致恢复失败、故障消失后重试成功及原始数据恢复。

---

### 6. 选择定位与暂停提示

**问题：** 复制/删除后选中项移动但视口不跟随；暂停状态在有历史时不可见。

**改动文件：**

| 文件 | 变更 |
|------|------|
| `Sources/PasteLite/App/AppState.swift` | `normalizeSelection` 支持 `resetIndex`；`selectedItem` 记录 `lastResolvedSelectionIndex` |
| `Sources/PasteLite/Views/HistoryPanelView.swift` | items/searchText/filter onChange 均触发 `scrollProxy.scrollTo`；顶部常驻"Recording paused / Resume"横幅 |

**回归测试：** `ReviewFixTests.keyboardSelectionScrollsIntoViewAndResetsOnPresentation`（既有，已适配）、`filteredSelectionSurvivesCaptureAndDeletion`（搜索/类型筛选双路径，覆盖新增保留选择、删除选择相邻项、条件变化和重新展示时重置）

---

### 7. 强调色对比度

**问题：** 八种强调色搭配白字对比度 1.96–4.20:1，全部不足。

**方案：** 从同一份精确 RGB 色值计算背景相对亮度，比较白色与 0.05 灰度深色的实际对比度，选择更高者。

**改动文件：**

| 文件 | 变更 |
|------|------|
| `Sources/PasteLite/Views/PasteLiteTheme.swift` | `PL.Accent` 新增 `foregroundColor` 和 `relativeLuminance` |
| `Sources/PasteLite/Views/HistoryPanelView.swift` | 筛选胶囊、主按钮使用动态前景色 |
| `Sources/PasteLite/Views/HistoryRowView.swift` | 选中行背景/前景使用 accent 动态色；次要文字不再额外降透明度 |

---

## 测试覆盖汇总

| 测试套件 | 新增/修改用例 | 说明 |
|----------|-------------|------|
| `DesignBehaviorTests` | `concealedUseDoesNotExtendItsFixedExpiry` | 数据库/内存双路径固定期限 |
| `DesignBehaviorTests` | `clipboardChangeDuringSourceSwitchIsNotCaptured` | 来源切换丢弃 |
| `DesignBehaviorTests` | `migrationKeepsExistingHistoryAndBlobs` | 旧库迁移回填 expires_at |
| `RegressionTests` | `tabUsesNativeFocusNavigationInsteadOfCyclingFilters` | Tab 原生焦点遍历 |
| `RegressionTests` | `commandCWithSelectedTextUsesNativeEventHandling` | 文本选区 Cmd-C 放行 |
| `RegressionTests` | `returnActivatesFocusedButtonInsteadOfHistoryAction` | 按钮 Return 原生激活 |
| `RegressionTests` | `returnInSearchStillDispatchesHistoryAction` | 搜索框 Return 历史操作 |
| `ReleaseReviewTests` | `revealingContentStopsAtItsExpiry` | 可控时钟到期遮罩 |
| `DesignBehaviorTests` | `roundTripAppSwitchIsDetectedAndSkipped` | 往返切换（A→排除→A）通知监听 |
| `DesignBehaviorTests` | `allAccentForegroundsMeetSmallTextContrast` | 解析实际 SwiftUI 色值，验证八色对比度均 ≥4.5:1 |
| `RegressionTests` | `failedUndoRetainsPayloadAndCanRetryAfterStorageRecovers` | 删除反馈、故障恢复后重试及载荷完整性 |
| `ReviewFixTests` | `filteredSelectionSurvivesCaptureAndDeletion` | 搜索/类型筛选下的选择保留、相邻删除与条件重置 |
| `ReleaseReviewTests` | `websiteMetadataSnapshotDoesNotShareMutableProviderState` | 预览元数据采用一次性主线程快照，保留图片载荷并隔离后续修改 |

**全量测试：** Debug 112 个测试、8 个套件；Release 111 个测试、7 个套件全部通过。仅使用 Debug fixture 的预览导出套件不参与 Release 测试编译。

---

## 验收返修（0.3.2 验收后）

### P1：通知中心错误

**问题：** `NSWorkspace.didActivateApplicationNotification` 注册到了 `NotificationCenter.default`，实际由 `NSWorkspace.shared.notificationCenter` 发送。往返切换（Editor→排除应用→Editor）时 bundle ID 相同，通知未接收导致 `sourceChanged = false`，排除内容被保存。

**修复：** 注册和移除均改用 `NSWorkspace.shared.notificationCenter`。回调明确位于主队列，同步设置切换标记，避免异步 Task 尚未执行时被紧接着的轮询漏判。

**回归测试：** `roundTripAppSwitchIsDetectedAndSkipped` 在两次工作区激活通知之间写入排除应用内容，不添加等待直接轮询，验证内容被跳过；随后复制稳定来源内容，验证正常捕获恢复。

### P2：Undo 载荷丢失与遮挡

**问题：** 失败时 `discardUndo()` 清空唯一撤销载荷；删除成功提示遮挡 Undo 按钮 3 秒（撤销窗口仅 5 秒）。

**修复：**
- Undo 失败保留 `deletedItem`，允许重试。
- 删除成功不再显示 statusMessage，Undo 立即可见。
- 有 `deletedItem` 时 Undo 始终显示，错误消息并排显示在右侧（红色）。
- 删除及重试恢复成功后清理旧错误，避免已经完成操作仍显示先前的失败。

### P2：对比度不足

**问题：** 亮度阈值 0.4 仅 Yellow 达到，其余七色仍用白字，对比度 2.53–4.20:1 全部不足 4.5:1。

**修复：** 从背景的精确十六进制值计算亮度，比较白色与近黑色（0.05 灰度）的实际对比度。移除选中行次要文字的 0.9 透明度衰减；筛选胶囊计数在选中时不透明；主按钮回车提示与选中行图标使用一致前景色。

**验证：** 测试解析实际 `NSColor` 色值，八色均达到 4.5:1，范围 **4.64–9.94:1**。

### P2：筛选中数据更新重置选择

**问题：** `resetIndex` 取决于当前是否在筛选状态，而非本次是否改变了筛选条件，导致新增记录或删除时选择跳回首项。

**修复：** `historyStore.items` onChange 调用 `normalize()`（不重置索引）；`searchText`/`selectedFilter` onChange 显式调用 `normalizeSelection(resetIndex: true)`。数据重排保留有效选中 ID，条件变化才重置。

选择规范化和键盘移动同步维护最近索引，保证相邻选择不依赖下一次视图读取；重新展示时清除旧索引，默认选择首项。新增真实 SwiftUI hosting view 回归，覆盖搜索和类型筛选两条路径。

---

## 0.3.2 封版检查

- 应用、打包脚本、CI 与版本测试统一为 **0.3.2 / build 32**。
- `SourceAppIcon` 缓存隔离到主线程；链接预览通过私有副本一次性交给主线程，避免跨执行上下文共享可变元数据，并保留图片提供者。
- 可控到期时钟使用 actor 隔离；Release 测试不再引用仅在 Debug 编译的预览 fixture。
- SQLite 的四处事务与迁移均在 `HistoryRepository` actor 内直接执行 BEGIN/COMMIT/ROLLBACK，不再通过事务回调捕获私有连接；保留失败回滚和提交后更新内存快照的规则。
- Debug、Release 全量测试均通过完整严格并发检查和 warnings-as-errors；CI 同步启用该检查。
- CI 串行运行共享 AppKit 全局状态的测试，避免不同套件争用应用与焦点状态；用例内部的显式并发验证保留。
- 开发工具记录和生成物排除出源码提交；公开验收文档移除本地工作目录与临时日志路径。
- 安装包、校验和及兼容性说明见 `docs/releases/0.3.2.md`。

---

## 待验证/待修复事项（批次三）

| 事项 | 类型 | 说明 |
|------|------|------|
| 重复筛选排序 profiling | 性能验证 | `LazyVStack` 限制可见行，但每行仍重复完整筛选排序；需 Instruments 或耗时埋点确认 |
| VoiceOver 行激活 | 可访问性验证 | 历史行只有合并信息，交互依赖 `onTapGesture`；需 VoiceOver 实测激活能力 |
| 双 Settings 窗口 | 行为验证 | SwiftUI `Settings` Scene 与手写 `NSWindow` 并存，需检查 Cmd-, 是否产生双窗口 |
| 增大文本/小屏幕适配 | 布局验证 | 固定窗口尺寸、固定小字号需走查 Dynamic Type 和小屏 |
| 默认快捷键冲突 | 产品决策 | ⇧⌘V 与常见"粘贴并匹配样式"冲突，建议改为 ⌃⌥V 或首次启动引导 |
| 菜单栏快捷键提示 | 功能验证 | ⌘, 和 ⌘Q 只是文本提示，未注册 `.keyboardShortcut` |

---

## 审查建议

1. **重点检查 `ClipboardMonitor` 来源切换逻辑**：保守策略会丢弃快速切换应用时的复制，确认是否符合产品预期。
2. **检查 `AppState.normalizeSelection` 的 `resetIndex` 逻辑**：搜索/筛选时重置为 0，删除时保持相邻索引，确认边界行为正确。
3. **检查实际对比度与透明度**：由渲染色值验证白色/深色候选，而非固定亮度阈值；选中行文字、筛选计数及主按钮提示不能额外衰减。
4. **确认 `ConcealedRevealModel` 注入式 `waitUntilExpiry` 的默认实现**：生产环境仍使用真实 `Task.sleep`，测试环境注入可控时钟。
5. **检查 `HistoryPanelView` 的 `scrollProxy` 持有方式**：`@State` 持有 `ScrollViewProxy`，在 `.onAppear` 赋值，items/searchText/filter onChange 中使用。

---

*最后更新：2026-11-06；四项返修阶段为 111 个测试，封版后 Debug 112 个、Release 111 个。*
