# 贡献指南

感谢你愿意参与 Starry Haven（星空难民营）。这份文档说明本项目的开发约定；如果你只是想使用软件，回到 [README](README.md) 即可。

## 开始之前

- 先搜索现有 Issue，避免重复。
- 功能改动先开 Issue 说明使用场景和预期行为；小的 bug 修复可以直接提交 PR。
- 涉及模型权重、第三方许可证、数据格式兼容性的改动，请先讨论。

## 环境

- macOS 14+
- Swift 6 工具链（Command Line Tools 足够）
- 可选：本地模型文件，目录结构见 README

```sh
swift build -c release
swift test
Scripts/build-app.sh release
open build/StarryHaven.app
```

## 代码分层

| 层 | 目录 | 规则 |
| --- | --- | --- |
| 处理核心 | `Sources/StarryHavenCore` | 不导入 AppKit，不读界面状态；输入输出可测试 |
| 界面 | `Sources/StarryHavenApp` | 只做状态、交互和展示；耗时的图像处理放到后台 |
| 命令行 | `Sources/StarryHavenCLI` | 与界面调用同一核心 API，不复制算法 |
| C 桥 | `Sources/COnnxRuntime` | 只做 ONNX Runtime 动态加载与调用 |

图像数据统一使用线性 float32 RGB。涉及色彩空间转换时，明确标注输入是 scene-referred 还是 display-referred。不要在新代码里另起一套像素格式。

## 代码风格

- 遵循 Swift API Design Guidelines；类型和函数用完整、可读的名字，避免缩写。
- 处理核心的 public API 要有简短文档注释，说明输入范围、返回值和失败条件。
- 优先使用 `throw` 和明确错误类型，不用静默失败；界面层负责把错误转成用户能看懂的提示。
- 不在处理核心中做 UI 弹窗、日志面板更新或文件选择。
- 注释只解释非显而易见的约束和算法来源，不叙述实现步骤。
- 不提交注释掉的旧代码、调试打印（测试与 CLI 输出除外）或无关格式化。

## 测试

- 核心逻辑改动必须新增或更新测试，测试调用真实实现，不复制算法到测试里。
- 测试数据尽量用合成星场；需要真实 RAW 时通过 `STARRYHAVEN_RAW_SAMPLE` 指定，不把个人路径写进测试。
- 模型相关测试在模型缺失时应自动跳过；不要把“本机路径存在”当作测试前提。
- 界面改动附上截图或录屏，说明操作路径和预期结果。
- 提交前至少运行：

```sh
swift build -c release
swift test
```

证据目录 `evidence/`、构建目录 `build/` 和 `.build/` 不提交。

## 提交信息

使用 Conventional Commits 风格：

```text
feat: add star mask feather control
fix: preserve FITS padding on 2D input
docs: clarify model directory layout
test: cover three-star rejection
refactor: split panorama canvas calculation
chore: update CI runner
```

- 标题用祈使句，不超过 72 个字符。
- 一个提交只解决一个问题；格式化、重命名和功能改动不要混在一起。
- 提交正文说明“为什么”，不要重复 diff 里的“做了什么”。

## 分支与 PR

- 从 `main` 创建短分支：`feat/short-name`、`fix/short-name`。
- PR 描述包含：问题、方案、验证方式、截图或日志。
- PR 合并前确保 CI 通过，且没有新增未讨论的依赖。
- 维护者使用 squash merge，保持 `main` 的历史清晰。

## 模型与资源

- 不提交 `.mlpackage`、`.mlmodelc`、`.onnx`、`LensProfiles.zip` 或任何模型权重。
- 不把模型、镜头配置或个人文件路径硬编码进代码；通过 `STARRYHAVEN_MODELS_DIR`、`ONNXRUNTIME_LIB`、`LENSFUN_DB` 等环境变量或标准目录查找。
- 新增第三方资源前确认许可证允许分发；不允许分发的资源只能由用户本地提供。
- 不提交个人收款码、邮箱以外的隐私信息；首页内容属于产品文案，修改前先讨论。

## 发布检查

1. `swift build -c release` 通过。
2. `swift test` 通过；模型缺失时确认跳过逻辑正常。
3. `Scripts/build-app.sh release` 生成 `build/StarryHaven.app`。
4. 启动应用，检查首页、帮助、星空堆栈、工具箱和至少一个附加工作区。
5. 更新 README 的功能或限制说明。
6. 打 tag：`v0.x.y`，并在 Release Notes 中列出行为变化和已知问题。

## 行为准则

参与本项目即表示同意遵守 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。技术讨论对事不对人；不接受人身攻击、歧视性言论或骚扰。

安全问题请按 [SECURITY.md](SECURITY.md) 私下报告，不要开公开 Issue。
