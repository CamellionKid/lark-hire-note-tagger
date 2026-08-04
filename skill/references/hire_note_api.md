# 飞书招聘人才与备注 API

执行 Hire 调用前读取本文件。以下规范来自飞书官方文档，并已在本机通过 `lark-cli api` 的 bot 身份验证人才搜索路径。

## 身份与权限

- 所有接口都传 `--as bot`，使用 `tenant_access_token`。
- 人才搜索/读取：`hire:talent:readonly` 或 `hire:talent`。
- 创建/更新备注：`hire:note`。
- 列表/获取备注：`hire:note:readonly` 或 `hire:note`。
- `auth login` 只处理用户 token，不能授予 bot 应用 scope。bot 缺 scope 时，错误 `99991672 app_scope_not_applied` 会给出 `console_url`，必须由应用管理员在开发者后台点击申请。

## 人才

### 搜索人才

`GET /open-apis/hire/v1/talents`

查询参数：

| 参数 | 类型 | 必填 | 说明 |
|---|---:|---:|---|
| `keyword` | string | 否 | 支持 `and` / `or` / `not` 的布尔搜索 |
| `page_size` | int | 否 | 默认 10，最大 20 |
| `sort_by` | int | 否 | `2` 为相关度降序 |
| `page_token` | string | 否 | 下一页标记 |
| `query_option` | string | 否 | 使用 `ignore_empty_error` 让无结果返回空数组，而不是 `1002002 IDList is empty` |

响应正文：`data.items[]`，人才 ID 为 `id`，姓名为 `basic_info.name`；分页字段为 `has_more` 和 `page_token`。

搜索结果可能是模糊匹配。必须在客户端按 `basic_info.name` 完全相等过滤；0 或多条精确结果都不能写入。

PowerShell 中调用 `.cmd` 时，内联 JSON 引号容易被 Windows 参数处理破坏。把 JSON 通过 stdin 传给 `--params -`：

```powershell
$params = @{ keyword = '张三'; page_size = 20; sort_by = 2; query_option = 'ignore_empty_error' } | ConvertTo-Json -Compress
$params | & "$env:APPDATA\npm\lark-cli.cmd" api GET /open-apis/hire/v1/talents --as bot --params - --jq '.'
```

### 获取单个人才

`GET /open-apis/hire/v1/talents/:talent_id`

用于验证用户消歧后提供的 talent ID。响应中的姓名位于 `data.basic_info.name`（部分封装版本可能多一层 `data.talent`，脚本兼容两种形状）。

## 备注

### 获取备注列表

`GET /open-apis/hire/v1/notes`

查询参数：

| 参数 | 类型 | 必填 | 说明 |
|---|---:|---:|---|
| `talent_id` | string | 是 | 人才 ID |
| `page_size` | int | 否 | 默认 10，最大 200 |
| `page_token` | string | 否 | 下一页标记 |

响应 `data.items[]` 常用字段：`id`、`talent_id`、`application_id`、`is_private`、`content`。使用 `has_more`、`page_token` 翻页。

### 创建备注

`POST /open-apis/hire/v1/notes`

请求体：

| 字段 | 类型 | 必填 | 说明 |
|---|---:|---:|---|
| `talent_id` | string | 是 | 人才 ID |
| `content` | string | 是 | 备注内容 |
| `privacy` | int | 否 | `1` 私密，`2` 公开；API 默认公开，但本 skill 必须显式传值 |
| `application_id` | string | 否 | 关联投递 ID |
| `creator_id` | string | 否 | 创建人 ID，类型需与 `user_id_type` 一致 |
| `notify_mentioned_user` | boolean | 否 | 默认 false |
| `mention_entity_list` | array | 否 | `[{offset, user_id}]`；@用户会同时赋予其查看该人才的权限 |

创建只需要 `hire:note`，仅自建应用支持。

### 获取备注

`GET /open-apis/hire/v1/notes/:note_id`

需要 `hire:note:readonly` 或 `hire:note`。

### 更新备注

`PATCH /open-apis/hire/v1/notes/:note_id`

必填请求体字段为 `content`；可选 `operator_id`、`notify_mentioned_user`、`mention_entity_list`。需要 `hire:note`。本 skill 的批量标签流程不修改既有备注，只追加新备注。

## 错误处理

| 错误码 | 含义 | 处理 |
|---:|---|---|
| `1002003` | user access token 不支持 | 改用 `--as bot`，不要继续用 user token |
| `99991672` | 应用未申请所需 scope | 原样展示 `console_url` 和二维码，等待管理员点击申请 |
| `1002002` | 参数错误 | 检查 JSON、必填字段和类型；人才无结果时确认已传 `query_option=ignore_empty_error` |
| `1002102` | 人才不存在 | 检查 talent ID，不写入 |

CLI 成功信封为 `{ok:true, identity:"bot", data:{...}}`；失败信封为 `{ok:false, error:{...}}`。始终按 `ok` 或退出码判断，不要按不存在的顶层 `code == 0` 判断。
