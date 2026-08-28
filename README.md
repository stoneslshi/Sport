# 燃知（SportHealth）

读懂健康，燃得明白。

一款读取 **Apple 健康** 数据的 iOS 应用：在本地完成运动 / 睡眠 / 身体统计，并可选接入 OpenAI 兼容大模型，生成上周图文周报与近况建议。也可导入 Garmin 数据管理导出的 FIT / ZIP。

## 功能概览

- **概览**：今日评分、缺口 CTA、提示与趋势
- **运动**：训练列表、类型过滤、轨迹回放、心率区间、爬升曲线、游泳明细；可导入 Garmin FIT
- **睡眠**：评分、分期、生命体征、与恢复关联
- **身体**：BMI / 体重趋势、恢复基线、代谢估算、VO₂ Max
- **建议**：上周 AI 周报（可分享）+ 近况建议 + 本地规则提示
- **设置**：活动能量目标、大模型、Garmin FIT / ZIP 导入

隐私优先：原始数据本机处理；AI 仅上传聚合统计摘要；API Key 存于 Keychain。

## 打开工程

```bash
open SportHealth/SportHealth.xcodeproj
```

- 系统要求：iOS 17+
- 需在真机授权 HealthKit 读取权限
- AI 功能在「设置」中配置服务商与 API Key
- Garmin：账号页「数据管理 → 导出数据」下载 ZIP，或从单场活动导出原始 FIT；在设置或运动页选择文件即可导入（本机解析，支持嵌套 `UploadedFiles_*.zip`）

## 交互原型

浏览器打开 `prototype/index.html` 可预览可点击原型。

## 设计文档

见 [`docs/设计文档.md`](docs/设计文档.md)。
