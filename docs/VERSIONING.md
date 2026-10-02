# LiteRead 版本发布流程规范

> 生效版本：1.0.1 起。本文档是版本号管理与发布流程的唯一规范，CI 会按此自动校验与递增。

## 1. 版本号规则（严格语义化）

- 格式：`X.Y.Z`（三位，每位 0–9），**上限 9.9.9**，超出上限时 CI 报错并要求人工评估。
- `pubspec.yaml` 的 `version:` 字段是**唯一版本源**（格式 `X.Y.Z+N`，`+N` 为构建号，由 CI 维护）。
- Git tag：发布正式版时打 `vX.Y.Z`，必须与 pubspec 版本一致，否则 release 流水线失败。
- 各位递增语义：
  - **Z（patch）**：Bug 修复、小改进 —— CI 在每次主干提交测试通过后自动 +1；
  - **Y（minor）**：新功能、功能性改进 —— 人工修改 pubspec（CI 会继续从该值递增）；
  - **X（major）**：不兼容的重大变更 —— 人工修改。
- 进位规则：`9 → 0` 并向前进一位（如 `1.0.9 → 1.1.0`，`1.9.9 → 2.0.0`）。

## 2. 自动递增机制（CI）

- 触发：推送到 `main` 且 `lint-test`（format/analyze/test）全部通过。
- 行为：`.github/workflows/ci.yml` 的 `bump-version` job 自动把 patch +1，以
  `chore(version): bump to vX.Y.Z [skip ci]` 提交并推送；`[skip ci]` 保证不会循环触发。
- 冲突处理：如他人同时推送导致 push 失败，可重跑该 job（checkout 已含 `fetch-depth: 0`）。

## 3. 发布流程

### 3.1 正式版（stable，推荐流程）

1. 确认 `main` 上 CI 全绿（版本号已由 CI 递增到位）。
2. 如需 minor/major 升级，先手动改 pubspec 并合入 main。
3. 打 tag 并推送（与 pubspec 一致）：
   ```bash
   # 示例：pubspec 为 1.2.0 时
   git tag v1.2.0 && git push origin v1.2.0
   ```
4. `.github/workflows/release.yml` 自动：构建 Android 签名 APK/AAB + Windows 便携包
   → 创建 GitHub Release（附 SHA256SUMS 与下载指引）→ `notify` job 写入发布通知。

### 3.2 测试版（beta）

- Actions 页手动运行 `release` workflow，选择 `beta` 通道：
  生成 `X.Y.Z-beta.N`（N 为流水线序号），以 prerelease 发布。

### 3.3 更新日志

- Release 说明由 `generate_release_notes` 依据 PR/commit 生成；
  重要变更请在合并 PR 时写清标题与描述，用户端「检查更新」弹窗会展示该内容。

## 4. 仓库内版本引用清单（改名/改版本时检查）

| 位置 | 说明 |
| --- | --- |
| `pubspec.yaml` | `version: X.Y.Z+N`（唯一版本源） |
| `lib/core/update/update_service.dart` | `kAppVersion`（与 pubspec 保持一致） |
| `.github/workflows/ci.yml` | `bump-version` 自动递增 |
| `.github/workflows/release.yml` | tag ↔ pubspec 一致性校验、上限校验 |
| 应用内「设置 → 检查更新」 | 读取 GitHub Releases 的 `tag_name` 比对 |

## 5. GitHub 仓库约定

- 仓库名：`LiteRead`（owner 下的规范名；引用一律使用
  `https://github.com/XingYuyuop/LiteRead`）。
- 应用内更新检查 API：
  `https://api.github.com/repos/XingYuyuop/LiteRead/releases/latest`。
