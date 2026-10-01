# 轻阅 LiteRead

轻量化多格式阅读器 —— 本地优先 / 无广告 / 无追踪 / 一切皆可调。

> 对标稻壳阅读器的开源实现，执行 [轻量阅读器开发计划书](轻量阅读器开发计划书.md)。

## 特性（当前进度）

- ✅ **M0 工程奠基**：Flutter 工程、Riverpod + go_router + Drift、5 套内置主题（纸白/米黄/夜间/墨黑/青竹）、CI 门禁
- ✅ **M1 阅读内核**：
  - EPUB 2/3 自研解析（zip → container.xml → OPF → spine，EPUB3 NAV / EPUB2 NCX 目录，加密文件明确拒绝）
  - Markdown（CommonMark + GFM）、TXT（UTF-8/UTF-16/GBK 编码探测 + 「第X章」智能分章）
  - 自研分页排版引擎：TextPainter 逐行测量、段落跨页切分、Locator（章 + 偏移）位置标识与排版参数无关
  - 阅读页：三区点按 / 拖拽翻页、覆盖/平移/淡入/无 四种动画、目录、进度条跳转、进度记忆（杀进程恢复）、字号/行距/段距/字距/页边距/缩进/两端对齐全部可调
- 🚧 M2 书架完善 + PDF（pdfrx）
- 🚧 M3 MOBI/AZW3（Rust FFI）+ 标注 + 全文搜索
- 🚧 M4 Windows 正式版 + 云端发布

## 平台

| 平台 | 状态 |
|---|---|
| Android 5.0+ | v1.0 |
| Windows 10 1809+ | v1.0 |
| macOS 12+ | M7 预留 |

## 开发

```bash
flutter pub get
flutter test          # 引擎单测（解析器 / 分页 / Locator）
flutter analyze
flutter run           # android / windows
```

工程结构（计划书 §3.8）：

```
lib/
├── app/                 # 入口、路由、全局 Provider
├── features/            # library / reader / settings（data·logic·presentation）
├── engine/              # 纯 Dart：ir / parsers / pagination
└── core/                # 主题、存储、平台适配
```

## CI/CD

- `ci.yml`：PR 门禁（format + analyze + test + 双平台 debug 冒烟）
- `release.yml`（M4 接入）：tag `v*` → 签名 APK/AAB + MSIX/Inno 安装器 → GitHub Release + SHA256SUMS

## 许可

见 LICENSE（MIT / Apache-2.0 待定，ADR-004）。禁止引入 GPL 代码（计划书 §3.9 准入清单）。
