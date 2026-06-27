# CPA 认证导入、额度缓存和用量费用设计

日期：2026-06-26

## 背景

本次改动只保留用户确认需要的功能：

- 认证文件支持粘贴 JSON 导入。
- 修复 Codex quota 前端缓存隔离和刷新后的旧数据展示问题。
- 在 Codex/OpenCode 额度管理中展示通过 CPA 实际代理请求产生的 token 用量和估算费用。
- 管理员可在管理页维护模型价格。

明确不做：

- 不合入 Codex 巡检功能。
- 不合入视觉效果性能模式。
- 不从 Codex 或 OpenCode 官网读取历史账单。
- 不引入 CPA-Manager-Plus 的完整独立 usage server 和大监控面板。

## 目标

1. 认证文件页面能直接粘贴 JSON 并保存为 `.json` 认证文件。
2. Codex quota 缓存按当前 CPA 环境和认证文件身份隔离，避免跨服务器、跨管理密钥或同名文件串数据。
3. 页面刷新后 Codex quota 不自动展示旧额度，和 OpenCode 额度页保持一致：刷新成功后才展开展示额度数据。
4. CPA 后端记录实际经过 CPA 的请求用量，并按账号、认证文件、API Key、提供商、模型、时间窗口汇总。
5. 管理页提供模型价格维护能力，费用估算使用管理员配置的价格。
6. Codex 和 OpenCode 额度卡展示当前账号的 token 消耗和估算美元费用。

## 认证文件粘贴导入

后端已有 `POST /auth-files?name=xxx.json` raw JSON 上传路径，会校验文件名后写入认证目录并注册认证记录。前端不需要新增后端接口。

管理页在认证文件页面增加“粘贴导入”入口。交互为：

- 打开弹窗。
- 输入文件名，自动补全或要求 `.json` 后缀。
- 粘贴 JSON 内容。
- 前端校验 JSON 必须能解析为对象。
- 调用现有 `authFilesApi.saveText(name, text)`。
- 成功后刷新认证文件列表并关闭弹窗。

错误处理：

- JSON 无法解析时在弹窗内提示。
- 文件名为空、非 `.json` 或包含路径分隔符时阻止提交。
- 后端返回错误时显示后端错误文本。

## Codex Quota 缓存隔离

当前 Codex quota 前端状态以文件名作为 key，容易在不同 CPA 地址、不同管理密钥环境或同名文件替换后串缓存。

新的缓存 key 使用稳定复合键：

```text
quotaKind | apiBase | managementKeyFingerprint | authIndex | fileName | providerType
```

说明：

- `apiBase` 使用当前管理页连接的 CPA base URL 标准化值。
- `managementKeyFingerprint` 只使用管理密钥的短 hash，不保存明文。
- `authIndex` 优先使用后端返回的 `auth_index`/`authIndex`。
- `fileName` 作为 fallback 和可读定位。
- `providerType` 防止不同 OAuth 类型复用同名文件时串状态。

页面刷新行为：

- 不从持久缓存恢复额度详情。
- 只在当前页面生命周期内保存刷新结果。
- 切换 CPA 地址、管理密钥或认证文件列表变更时清理不匹配的 quota state。

## 用量统计后端

CPA 已经在 usage record 中拥有请求级 token 字段，包括输入、输出、reasoning、cached、cache read、cache creation 和 total tokens。本次新增一个轻量持久化统计层，不消费现有 usage queue。

### 数据来源

在 usage record 被发布或处理时，额外写入 usage aggregator。统计只覆盖成功进入 CPA 代理流程并产生 usage record 的请求。

### 聚合维度

每条记录归档以下字段：

- 时间戳。
- provider。
- model。
- endpoint。
- auth_index。
- auth file name 或 auth id。
- API Key 标识，保存短 hash 或后端已有脱敏标识，不保存明文。
- OpenCode account id/source，如果请求可映射到 OpenCode Go 托管 key。
- 输入、输出、reasoning、cached、cache read、cache creation、total tokens。
- 请求成功/失败状态。
- service tier。

### 存储方式

使用 CPA 本地数据目录下的 SQLite 存储，但不让额度页直接扫描长期明细表。数据分为两层：

- 原始请求明细表：保留 60 天，用于排查和重新聚合。
- 聚合表：写入请求时同步更新，额度页和用量接口优先读取聚合表。

这样保留 SQLite 的单机部署便利，同时避免请求量增长后每次打开额度页都扫描大表。

原始明细表：

```text
usage_events(
  id,
  request_id,
  timestamp_ms,
  provider,
  model,
  endpoint,
  auth_index,
  auth_file_name,
  api_key_hash,
  account_ref,
  service_tier,
  input_tokens,
  output_tokens,
  reasoning_tokens,
  cached_tokens,
  cache_read_tokens,
  cache_creation_tokens,
  total_tokens,
  failed
)
```

原始明细索引：

- `timestamp_ms`
- `(provider, auth_index, timestamp_ms)`
- `(provider, account_ref, timestamp_ms)`
- `(api_key_hash, timestamp_ms)`
- `(model, timestamp_ms)`

聚合表：

```text
usage_rollups(
  bucket_kind,
  bucket_start_ms,
  provider,
  model,
  auth_index,
  auth_file_name,
  api_key_hash,
  account_ref,
  service_tier,
  request_count,
  failed_count,
  input_tokens,
  output_tokens,
  reasoning_tokens,
  cached_tokens,
  cache_read_tokens,
  cache_creation_tokens,
  total_tokens,
  updated_at_ms
)
```

`bucket_kind` 初始支持：

- `hour`：用于 5h 和 7d 这类滚动窗口。
- `day`：用于 month 和长期趋势。

聚合表唯一键：

```text
bucket_kind,
bucket_start_ms,
provider,
model,
auth_index,
api_key_hash,
account_ref,
service_tier
```

每次写入 usage event 时，在同一个事务中更新对应小时和日期聚合行。前端额度页查询只读聚合表，最多补查 60 天内的原始明细用于诊断接口。

去重：

- 如果 `request_id` 存在，使用唯一索引避免重复写入。
- 没有 `request_id` 时允许写入，但不会主动合并。
- 只有原始明细成功插入后才更新聚合表，避免重复 request_id 重复累计。

保留周期：

- 原始请求明细默认保留 60 天。
- 聚合表长期保留，后续可加管理配置调整压缩或清理策略。

## 模型价格

后端新增模型价格管理 API，由管理员在 management 页面维护。价格单位均为 USD / 1M token。

价格字段：

- model。
- input_per_1m。
- output_per_1m。
- cache_read_per_1m。
- cache_creation_per_1m。
- optional cached_per_1m，用于兼容只提供总 cached token 的模型。
- source，记录 `manual` 或未来同步来源。
- updated_at。

价格匹配规则：

1. 精确匹配模型名。
2. 可选支持通配前缀，例如 `gpt-5*`，优先级低于精确匹配。
3. 没有匹配价格时，仍返回 token 汇总，费用字段为 null，并在前端显示“未配置价格”。

费用公式：

```text
billableInput = max(input_tokens - cache_read_tokens - cache_creation_tokens, 0)
cost =
  billableInput / 1_000_000 * input_per_1m +
  output_tokens / 1_000_000 * output_per_1m +
  cache_read_tokens / 1_000_000 * cache_read_per_1m +
  cache_creation_tokens / 1_000_000 * cache_creation_per_1m
```

reasoning token 如果上游已计入 output tokens，则不重复计费；如果某 provider 只提供独立 reasoning tokens，先计入 output 侧估算。

## 管理 API

新增后端 API：

- `GET /model-prices`：列出模型价格。
- `PUT /model-prices`：批量替换模型价格。
- `PATCH /model-prices/:model`：新增或更新单个模型价格。
- `DELETE /model-prices/:model`：删除单个模型价格。
- `GET /usage-summary`：按 provider、auth_index、account_ref、api_key_hash、window 查询聚合用量和估算费用。
- `POST /opencode-go/accounts/:id/refresh-usage`：刷新 OpenCode Go 官方额度，并在后端附带同窗口内的 CPA 消耗和估算费用。

`GET /usage-summary` 支持参数：

- `provider`
- `auth_index`
- `account_ref`
- `api_key_hash`
- `model`
- `window`，支持 `5h`、`7d`、`month`
- `window_start_ms` 和 `window_end_ms`，可选；前端拿到官方额度窗口边界时传入，优先级高于 `window`

返回包含：

- 总 token 和各 token bucket。
- estimated_cost_usd，无法估算时为 null。
- missing_price_models。
- 按模型拆分的 rows。
- 数据来源标识，默认从聚合表读取。

### 消耗归属规则

额度页展示的 CPA 消耗必须只统计当前卡片对应的账号或凭证，不显示全局消耗。

Codex 额度卡：

- 查询条件必须包含 `provider=codex` 和当前认证文件的 `auth_index`。
- 统计范围是这个认证文件实际被 CPA 选中执行的 Codex 请求。
- 同一个模型在其他认证文件上的消耗不能计入当前卡片。
- 卡片总量展示当前认证文件所有 Codex/GPT 模型的合计，详情 rows 按模型拆分，例如 `gpt-5.5`、`gpt-5.3-codex-spark`。

OpenCode Go 额度卡：

- 查询条件必须绑定当前 OpenCode Go 账号对应的 API key。
- 优先使用账号对应的 `account_ref` 或托管 provider key source，例如 `opencode-go:<account-id>`。
- 同时保存和查询 `api_key_hash` 作为兜底匹配条件。
- 如果多个 OpenCode Go 账号在同一个 provider 下，不能聚合整个 `opencode-go` provider 的用量，只能显示当前账号 API key 的消耗。
- 如果当前账号没有 API key 或无法建立 key/source 映射，`cpa-usage` 返回空数据，并在前端显示暂无通过 CPA 的请求用量。

### OpenCode Go 后端聚合

OpenCode Go 当前已经由 CPA 后端通过 cookie 刷新官方额度，前端只调用 `refresh-usage` 并渲染返回值。新增 CPA 消耗后，OpenCode Go 不让前端再单独调用 `usage-summary` 拼装数据。

`POST /opencode-go/accounts/:id/refresh-usage` 的后端流程：

1. 使用账号 cookie 请求 OpenCode Go 官方额度。
2. 解析 `rolling`、`weekly`、`monthly` 三个官方窗口的 `used`、`limit`、`reset-at`。
3. 根据窗口类型和 `reset-at` 计算当前窗口边界：
   - `rolling` 使用 5h 窗口。
   - `weekly` 使用 7 天窗口。
   - `monthly` 使用一个月窗口。
4. 使用账号的 `account_ref`、托管 provider key source 或当前账号 API key hash 查询 CPA usage rollup。
5. 使用管理员配置的模型价格计算每个窗口内的 estimated cost。
6. 在同一个响应里返回官方额度和 CPA 消耗。

响应在 account 上增加 `cpa-usage`：

```text
cpa-usage: {
  rolling: UsageSummaryWindow,
  weekly: UsageSummaryWindow,
  monthly: UsageSummaryWindow
}
```

`UsageSummaryWindow` 包含窗口起止时间、token bucket、estimated_cost_usd、missing_price_models 和按模型拆分 rows。

## Management 前端

### 模型价格设置

在管理员设置中增加“模型价格”管理区：

- 表格展示模型、输入、输出、缓存读取、缓存写入、更新时间。
- 支持新增、编辑、删除。
- 支持批量粘贴 JSON 或 CSV 作为后续增强，本次先做表单和表格。

### 额度卡展示

额度管理页前端展示顺序固定为：

1. Codex 额度。
2. OpenCode Go 额度。
3. Claude 额度。
4. Antigravity 额度。
5. 其他已有额度区保持现有相对顺序。

Codex 额度卡刷新成功后，并发拉取 `usage-summary`：

- Codex 使用当前认证文件的 `auth_index` 查询。
- Codex 展示与官方额度窗口一致的消耗，默认优先显示 `5h`、`7d`、`month`。
- 如果官方额度接口返回窗口 reset time 或 duration，前端计算当前窗口边界并传 `window_start_ms/window_end_ms` 查询 CPA 用量。
- 如果没有窗口边界，后端按滚动 `5h`、`7d`、`month` 查询。
- 可在卡片内切换 `5h 窗口期 / 7 天窗口期 / 一个月窗口期`。
- 没有请求记录时显示“暂无通过 CPA 的请求用量”。
- 有 token 但缺价格时显示 token，费用显示“未配置价格”。

OpenCode Go 额度卡直接使用 `refresh-usage` 返回的 `usage` 和 `cpa-usage`：

- 前端不再单独为 OpenCode Go 拼 `usage-summary` 参数。
- `rolling`、`weekly`、`monthly` 三个窗口同时展示官方剩余额度和 CPA 实际消耗。
- 页面刷新后仍不展示旧额度，只有点击刷新并拿到后端响应后才展开。

### 认证文件粘贴导入 UI

入口放在认证文件上传区域，和文件上传平级，不新增独立页面。

## 测试

后端测试：

- raw JSON 上传路径已有基础覆盖时补充前端集成即可；如缺少边界覆盖，补充 `.json` 文件名和非法 JSON auth build 失败用例。
- usage event 写入测试：同一 request_id 去重、token bucket 正确落库。
- usage rollup 测试：写入明细时同步更新小时和每日聚合，同一 request_id 不重复累计。
- usage summary 测试：按 auth_index、provider、时间窗口过滤，并优先从聚合表读取。
- OpenCode Go refresh usage 测试：返回官方 usage 时同时返回 `cpa-usage`，窗口边界由 `reset-at` 和窗口类型计算。
- retention 测试：原始明细超过 60 天会被清理，聚合数据保留。
- model price 测试：精确匹配、通配匹配、缺失价格返回 null。
- cost formula 测试：缓存读取/写入不重复计入普通 input。

前端测试：

- 粘贴导入弹窗校验 JSON 和文件名。
- Codex quota cache key 在不同 apiBase/management key/auth_index 下不同。
- 刷新页面不恢复旧 quota 详情。
- usage summary 卡片在有费用、缺价格、无数据三种状态下显示正确。
- 模型价格表单保存、删除和错误提示。

## 迁移和兼容

- 新增 usage SQLite 文件不存在时自动创建。
- 原始 usage 明细默认只保留 60 天，避免本机数据库无限增长。
- 额度页和 summary API 默认读取聚合表，避免因明细数据增长导致页面变慢。
- 旧配置无需迁移。
- 没有配置模型价格时，功能仍可显示 token，不显示美元估算。
- 现有 usage queue 行为不改变，避免影响外部 usage keeper。

## 发布顺序

1. 后端加入 usage 存储、价格 API、summary API。
2. 管理页加入模型价格设置。
3. 管理页加入认证文件粘贴导入。
4. 管理页修复 Codex quota cache key 和刷新行为。
5. 管理页调整额度区顺序为 Codex、OpenCode Go、Claude、Antigravity、其他。
6. 后端在 OpenCode Go `refresh-usage` 响应中附带 CPA 消耗。
7. 管理页在 Codex 额度卡接入 usage summary。
8. 管理页在 OpenCode Go 额度卡展示 `refresh-usage` 后端返回的 CPA 消耗。
9. 构建 Docker 并部署堡垒机验证。

## 验收标准

- 可以在认证文件页面粘贴 JSON 保存为认证文件。
- 同名认证文件在不同 CPA 环境下不会共享 Codex quota 状态。
- 额度管理页最上方先显示 Codex 额度，其次显示 OpenCode Go 额度。
- 刷新 management 页面后，Codex/OpenCode 不展示旧额度详情。
- 管理员可以新增并保存模型价格。
- 通过 CPA 调用模型后，额度页能看到对应账号的 token 消耗。
- 配置模型价格后，额度页显示估算美元费用。
- 未配置价格时，费用不会显示错误值。
