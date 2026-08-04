---
name: lark-hire-note-tagger
description: "从飞书 Base、多维表格、电子表格或文档中读取候选人姓名与标签，在飞书招聘中精确匹配人才、去重并批量写入标签备注。用户提供飞书链接并要求给候选人打标签、同步标签到招聘备注、批量添加人才备注，或需要处理 Hire 备注权限时使用。"
---

# 飞书招聘候选人标签备注

将飞书数据源中的 `[{name, tags}]` 安全地同步为飞书招聘人才备注。所有 Hire API 都使用应用身份（`--as bot`）；姓名不唯一时绝不猜测。

## 前置规则

1. 先完整阅读 [`../lark-shared/SKILL.md`](../lark-shared/SKILL.md)，遵守其中的 URL/二维码转发、身份和写入确认规则。
2. 首次执行 Hire 调用前阅读 [`references/hire_note_api.md`](references/hire_note_api.md)。不要猜测路径、参数或响应结构。
3. 仅通过 `lark-cli api ... --as bot` 调用 Hire。Hire 接口使用 `tenant_access_token`；不要用 `--as user`，也不要用 `auth login` 修复 bot scope。
4. 未明确备注隐私时，先询问用户选择：私密（`privacy=1`）或公开（`privacy=2`）。不得依赖 API 的公开默认值。
5. 写入前先预览并获得用户对本次具体写入的明确确认。

## 工作流

### 1. 检查权限

运行：

```powershell
& "$env:USERPROFILE\.agents\skills\lark-hire-note-tagger\scripts\check_permissions.ps1"
```

脚本同时给出用户 token 的 `auth check` 诊断和决定实际 Hire 能否工作的 bot 探测结果。按返回值处理：

- `ready`：继续。
- `human_action_required`：错误为 `app_scope_not_applied`（`99991672`）。将 `console_url` 原样作为可点击链接发给用户，并按 `lark-shared` 要求运行 `lark-cli auth qrcode <console_url> --output <cwd下的相对PNG路径>` 生成、展示二维码。明确说明此步骤必须由应用管理员点击完成，agent 无法绕过；结束当前轮。用户确认完成后重新运行检查。
- `probe_failed`：报告结构化错误并停止，不要尝试写入。

`auth check` 可能建议 `auth login`，但它检查的是用户授权，不能授予 `--as bot` 所需的应用权限；不要执行该建议来修复 Hire bot 权限。

创建和读取备注时申请 `hire:note` 即可；`hire:note:readonly` 是只读替代 scope。人才搜索需要 `hire:talent:readonly`（或 `hire:talent`）。

### 2. 读取来源链接

根据 URL 路径或资源类型切换到相应 skill，并完整遵守其读取说明：

- Base / 多维表格 / `/base/`：[`../lark-base/SKILL.md`](../lark-base/SKILL.md)
- 电子表格 / `/sheets/`：[`../lark-sheets/SKILL.md`](../lark-sheets/SKILL.md)
- Docx、Wiki 文档 / `/docx/`、`/wiki/`：[`../lark-doc/SKILL.md`](../lark-doc/SKILL.md)

提取为 UTF-8 JSON 数组：

```json
[
  {"name":"张三","tags":["产品经理","一面通过"]},
  {"name":"李四","tags":["Java","重点跟进"],"application_id":"可选"}
]
```

去除姓名和标签首尾空白，删除空标签，同一行标签去重。姓名或标签为空的行标为无效，不写入。不要自行拆分含义不明确的自由文本。

### 3. 只读匹配并消歧

把 JSON 保存到临时文件，先只运行人才搜索：

```powershell
& "$env:USERPROFILE\.agents\skills\lark-hire-note-tagger\scripts\tag_talents.ps1" `
  -InputPath "<pairs.json>" -Mode SearchOnly
```

脚本使用 `keyword=<name>`、`query_option=ignore_empty_error` 搜索，并在客户端只保留 `basic_info.name` 完全相等的结果：

- 0 个精确结果：状态为 `not_found`；询问用户补充信息或正确姓名。
- 1 个精确结果：继续。
- 多个精确结果：状态为 `ambiguous`；展示返回的候选 talent ID 和脱敏联系方式，让用户选择。
- 搜索达到分页安全上限仍有更多结果：状态为 `ambiguous`，原因是 `search_truncated`；不得采用当前唯一结果。

用户消歧后，在对应输入项加入明确的 `talent_id`。脚本会通过 `GET /talents/:talent_id` 回读并验证姓名一致；验证失败不写入。

先收集所有 `not_found` / `ambiguous` 项，一次性请用户处理。其他明确匹配项也不要提前写入。

### 4. 去重并预览

获得隐私选择且全部必要消歧完成后运行：

```powershell
& "$env:USERPROFILE\.agents\skills\lark-hire-note-tagger\scripts\tag_talents.ps1" `
  -InputPath "<pairs.json>" -Mode Preview -Privacy <1或2>
```

默认内容格式为 `候选人标签：标签1、标签2`。脚本分页读取该人才的全部备注；若已有备注内容与格式化结果完全一致，状态为 `skipped_duplicate`，否则为 `would_create`。已有不同标签备注不会被修改或覆盖；本次会追加新备注。

向用户展示预览表（姓名、talent_id、隐私、状态、备注内容），明确询问是否创建所有 `would_create` 项。

### 5. 确认后写入

仅在用户明确确认本次预览后运行：

```powershell
& "$env:USERPROFILE\.agents\skills\lark-hire-note-tagger\scripts\tag_talents.ps1" `
  -InputPath "<pairs.json>" -Mode Write -Privacy <1或2> -ConfirmWrite
```

脚本在每次 POST 前重新读取备注做幂等检查，降低预览与写入之间产生重复备注的风险。不要通过自动补加 `-ConfirmWrite` 绕过确认。

### 6. 报告结果

用表格报告：`name → talent_id → status → note_id/content`。状态至少区分：

- `created`
- `skipped_duplicate`
- `ambiguous`
- `not_found`
- `invalid_input`
- `api_error`

报告部分成功时明确列出未写入项；不要把部分成功描述成全部完成。

## 脚本输入约定

- `tags` 可为字符串或字符串数组；数组是推荐形式。
- `talent_id` 仅用于用户完成消歧后的精确覆盖，脚本仍会回读验证姓名。
- `application_id` 可选；提供时把备注关联到该投递。
- `Privacy` 必须显式为 `1`（私密）或 `2`（公开）。
- `SearchOnly` 不读取或写入备注；`Preview` 只读；`Write` 是唯一创建备注的模式。
