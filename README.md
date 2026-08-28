# 燃知（SportHealth）

读懂健康，燃得明白。

一款读取 **Apple 健康** 数据的 iOS 应用：在本地完成运动 / 睡眠 / 身体统计，并可选接入 OpenAI 兼容大模型，生成上周图文周报与近况建议。

## 功能概览

- **概览**：今日评分、缺口 CTA、提示与趋势
- **运动**：训练列表、类型过滤、轨迹回放、心率区间、爬升曲线、游泳明细
- **睡眠**：评分、分期、生命体征、与恢复关联
- **身体**：BMI / 体重趋势、恢复基线、代谢估算、VO₂ Max
- **建议**：上周 AI 周报（可分享）+ 近况建议 + 本地规则提示

隐私优先：原始数据本机处理；AI 仅上传聚合统计摘要；API Key 存于 Keychain。

## 打开工程（本地开发调试）

```bash
git clone https://github.com/stoneslshi/Sport.git
cd Sport
open SportHealth/SportHealth.xcodeproj
```

在 Xcode 中选择 Scheme **SportHealth**，按 `⌘R` 运行。

### 环境要求

- macOS + Xcode 16+（工程 `LastUpgradeCheck = 2630`）
- 部署目标 iOS 17+，仅 iPhone
- Apple ID / 开发者团队（Signing 已填 `DEVELOPMENT_TEAM = 6P4KARSH3X`，换机器时在 Target → Signing & Capabilities 改成自己的 Team）
- **完整 HealthKit 数据请用真机**；模拟器可授权，但通常没有运动 / 睡眠记录

### 模拟器调试

Debug 包在模拟器上会默认加载**示例数据**（概览有提示条），可预览五 Tab、运动详情（跑步轨迹 / 游泳趟表 / 心率五区）、周报卡片。  
到「设置 → 本地调试」关闭「使用示例数据」后，会走真实 HealthKit（模拟器里一般为空）。此开关只存在于 Debug，不会进 Release。

### 真机调试

1. 用数据线连接 iPhone，打开 **设置 → 隐私与安全性 → 开发者模式**
2. Xcode 顶部设备选真机，`⌘R` 安装
3. 首次打开点「授权并加载数据」，在系统弹窗中允许读取健康数据
4. AI 周报 / 近况建议：在设置里配置 OpenAI 兼容服务商与 API Key（Key 只存 Keychain）

### 交互原型（不需要 Xcode）

浏览器打开 `prototype/index.html` 可预览可点击原型。

## 设计文档

见 [`docs/设计文档.md`](docs/设计文档.md)。
