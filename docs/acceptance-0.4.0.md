# PasteLite 0.4.0 发布验收

验收对象：0.4.0 / build 40；开发分支 `codex/0.4.0-library`，发布分支 `codex/release-0.4.0`。

基线：0.3.2 / `7c24d6c`。

开发提交：`41c4415`（收藏库、片段、数据迁移、验证与候选版本构建配置）。

当前结论：**核心开发和本地自动验收完成，双架构安装包已验证；本轮按用户指令推进 0.4.0 正式发布。未完成的实机交互验证作为已知限制公开记录。**

## 实现结果

| 计划范围 | 实现 |
| --- | --- |
| 独立收藏 | 原样保存文本、代码、链接、颜色、图片和文件引用；独立载荷和 UUID；历史清理与重新捕获不改变收藏 |
| 分组与名称 | 全部收藏、未分组和一级自建分组；新建、重命名、移动、删除组；用户名称搜索 |
| 文本片段 | 手动创建或从历史文字创建副本；文本/代码类型、多行纯文本编辑；1 MiB UTF-8 上限 |
| 面板与调用 | History/Saved、Ctrl-Tab、Cmd-N、Cmd-E、Cmd-Return；保留既有 Return、纯文本反转和数字快捷键 |
| 持久化与迁移 | schema v4；普通旧置顶迁入未分组，旧机密置顶保留原期限；事务失败回滚、重试不重复 |
| 生命周期 | 普通历史与收藏分别清空；五秒删除撤销统一覆盖两类内容；退出清空覆盖所有表和资产 |
| 隐私与失败反馈 | 机密标记禁止永久保存；数据库不可用时禁止宣称收藏成功；清空/编辑后旧选择不可写回；失效文件引用报错 |

实现继续让 `HistoryRepository` actor 独占 SQLite 连接，通过 `LibraryRepository.swift` 的扩展增加收藏能力。现有 `SQLiteHistoryStore` 同时发布历史和收藏的带修订号快照，避免两套 Store 的事务和撤销状态不同步。没有为收藏再打开第二个数据库连接；这是对计划中建议文件拆分的实现调整。

收藏载荷和缩略图通过 `ClipboardOrigin` 识别来源，片段编辑带修订号校验。搜索结果在后台计算，界面和键盘操作使用同一份结果；旧请求不能覆盖新查询。

首次发布流水线发现 runner 工具链不接受事务回调捕获 SQLite 连接。本轮将收藏写入改为值类型操作，由 repository actor 直接执行 SQL、提交和回滚；没有把数据库连接标记为可跨线程共享。

## 自动验证

| 检查 | 结果 |
| --- | --- |
| 开发前基线 | Debug 112 个测试、8 个套件通过 |
| 最终 Debug | **142 个测试、10 个套件通过** |
| 最终 Release | **141 个测试、9 个套件通过**；Debug 专用原生预览套件不参与 Release |
| 并发检查 | 两种配置均开启 `-strict-concurrency=complete` 与 `-warnings-as-errors` |
| 原生渲染 | 28 张，覆盖历史、收藏、紧凑模式、片段编辑器、预览、设置及明暗主题；查看了收藏与编辑器的关键渲染 |
| 实际候选包更新验证 | 候选 `.app` 的归档、校验和、身份/版本/签名验证；真实 bundle 的安装替换成功及失败回滚通过 |
| 重复退出 | 独立 Debug 应用正常退出，SQLite 中历史、历史附件、收藏、收藏附件和分组均为零 |

新增测试涉及：

- v1/v2/v3 迁移、原始格式与使用信息、重复启动、迁移注入失败和恢复重试。
- 源历史删除、容量淘汰、同 hash 重新捕获，以及用户命名时源历史被淘汰。
- 原样收藏去重保留名称/分组，片段正文相同仍允许独立保存。
- 片段多行/空白、中文、代码、1 MiB 边界与超限拒绝、编辑后旧修订号失效。
- 分组重名、内建名称保护、移动与删除不丢内容。
- 保存失败事务回滚、撤销恢复失败后重试、清空后的旧草稿与 Undo 不复活数据。
- 暂停采集不破坏编辑草稿，存储恢复后保留内存历史并允许保存。
- 名称优先排序、中文正文和来源搜索、分组与类型组合、切换模式及删除后的选择。
- 收藏独立载荷复制、片段安全粘贴、清空发生于目标激活等待阶段时不发送 Paste。

现有图片测试不再假定 `NSCache` 必然返回同一对象实例，改为验证缩略图尺寸和清空后不可读取的行为。缓存可按系统策略驱逐，指针相同不是可承诺的用户行为。

## 性能记录

环境：Apple Silicon，`Mac16,10`，16 GiB 内存，macOS 27.0.1。

合成数据：5,000 条历史、200 条收藏；30 次查询，交替检索历史和收藏。

| 指标 | 结果 |
| --- | --- |
| Debug 查询计算 p95 | 23.69 ms |
| Release 查询计算 p95 | 15.76 ms |
| 1 MiB 片段存储与载荷读取 | 边界回归通过 |

这里测量的是筛选、排序及计数计算，**不包括**窗口展示、SwiftUI 绘制和键盘输入送达时间。计划中的热呼出 p95 ≤200 ms、输入至可见结果 p95 ≤150 ms 尚未完成端到端测量。

GitHub 共享 Intel runner 的 Debug 测量曾为 217.79 ms，不与上述参考机器的 Release 数值直接比较。常规 CI 验证两组查询的准确结果数并记录耗时；只有设置 `PASTELITE_QUERY_P95_BUDGET_MS` 时才执行对应环境的耗时预算断言。

## 候选包

正式发布包输出在本地 `dist/0.4.0-release/release/`，包含 arm64 和 x86_64 的 `.dmg`、`.app.zip` 与 SHA-256 文件。两种 Release 构建、架构检查、签名、plist、最低系统版本及镜像内部校验通过。

签名方式延续现有项目：ad-hoc，未 notarize。候选包没有新增依赖。

```text
be8fc10e848a4d0aafaca50d28975a291d9160603c51ee32aac1ceb6f15d9a36  PasteLite-0.4.0-macos-arm64.dmg
9187fcd90f41b7ebee303ea894a45a562968d6b3b959509646e71a04aa56409a  PasteLite-0.4.0-macos-x86_64.dmg
```

安装包挂载后的隔离启动结果记录在本地 `outputs/0.4.0-release/verification.json`，不随源码分发。该验证与手动交互验收分开记录。

两张 DMG 均已只读挂载，复制出的应用通过版本、架构、签名、归档内容和开发数据检查。arm64 原生运行、x86_64 经 Rosetta 运行均完成启动，创建 schema v4 的独立空数据库。验证等待迁移完成后再检查库版本，避免把数据库文件刚创建、事务尚未提交的阶段误判为启动失败。

## 尚待实机验收

原生计算机交互服务在使用应用路径、bundle ID 和注册后的 bundle ID 连接时均返回超时；本次无法完成完整的 UI 操作走查。以下项目仍未宣称通过：

- TextEdit、浏览器输入框及代码编辑器的真实跨应用粘贴。
- 全局快捷键呼出、快速切换来源应用时的实际漏记范围。
- 编辑器中真实中文输入法组合、选区复制、焦点导航、未保存关闭及退出提示。
- 完整 VoiceOver 行激活、分组/片段编辑，以及小屏和文字放大走查。
- 热呼出和输入至可见结果的端到端性能测量。
- macOS 12 与物理 Intel 机器的运行验证；Rosetta 不能替代物理 Intel。
- 0.3.2 已记录的默认快捷键冲突、双 Settings 窗口等旧问题的实机确认。

以上缺口不以构建、原生静态渲染或可注入行为测试代替。本轮发布说明列出这些限制，后续通过可用设备补充交互验收，并处理新发现的问题。

## 复验

测试夹具使用临时数据库和独立剪贴板；原生渲染、重复退出及候选包启动使用独立数据目录和偏好套件。典型命令：

```sh
verification_dir="$(mktemp -d)"
PASTELITE_DATA_DIRECTORY="$verification_dir/data" \
PASTELITE_PREFERENCES_SUITE=PasteLite.Verification040 \
SWIFT_TEST_BUILD_SYSTEM=native \
SWIFT_TEST_SCRATCH_PATH="$verification_dir/build" \
./script/run_checks.sh --no-parallel \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors

DIST_DIR="$PWD/dist/0.4.0-release" \
SWIFT_BUILD_SYSTEM=native \
./script/package_release.sh

python3 script/verify_candidate.py dist/0.4.0-release/release \
  --output outputs/0.4.0-release/verification.json

PASTELITE_UPDATE_TEST_APP="$PWD/dist/0.4.0-release/release/stage-arm64/PasteLite.app" \
./script/run_checks.sh --no-parallel --filter UpdateInstallationTests

python3 script/review_runtime.py dist/0.4.0-preview/PasteLite.app

PASTELITE_QUERY_P95_BUDGET_MS=150 \
./script/run_checks.sh -c release --no-parallel \
  --filter LibraryBehaviorTests.queryTimingWithFiveThousandHistoryItems
```

最后一条需要使用带 `--ui-preview` 支持的 Debug app；Release 中不包含示例数据和退出测试入口。
