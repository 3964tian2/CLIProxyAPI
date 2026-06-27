# CPA Auth Import, Quota Cache, Usage Cost Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add pasted auth-file import, isolated quota cache behavior, model price management, and CPA-only token/cost usage display for Codex and OpenCode Go.

**Architecture:** The backend owns usage capture, model prices, aggregation, retention, and OpenCode Go usage composition. The management frontend renders backend-provided usage summaries, provides model price editing, adds pasted auth-file import, and reorders quota sections so Codex and OpenCode Go lead the page.

**Tech Stack:** Go 1.26, Gin management API, `sdk/cliproxy/usage` plugin hooks, SQLite via `database/sql` and a pure Go driver, React 19, TypeScript, Vite, Zustand.

---

## File Structure

Backend repository: `/Users/kogeki/dev/CLIProxyAPI`

- Create `/Users/kogeki/dev/CLIProxyAPI/internal/usageledger/types.go`: shared usage event, token, rollup, price, and summary types.
- Create `/Users/kogeki/dev/CLIProxyAPI/internal/usageledger/pricing.go`: model price matching and USD cost calculation.
- Create `/Users/kogeki/dev/CLIProxyAPI/internal/usageledger/sqlite_store.go`: SQLite schema, migrations, writes, rollup queries, price CRUD, retention cleanup.
- Create `/Users/kogeki/dev/CLIProxyAPI/internal/usageledger/plugin.go`: `sdk/cliproxy/usage.Plugin` implementation and request record normalization.
- Create `/Users/kogeki/dev/CLIProxyAPI/internal/usageledger/window.go`: 5h, 7d, month, and reset-at based window boundary helpers.
- Create `/Users/kogeki/dev/CLIProxyAPI/internal/usageledger/*_test.go`: pricing, store, plugin, and window tests.
- Create `/Users/kogeki/dev/CLIProxyAPI/internal/api/handlers/management/model_prices.go`: model price management handlers.
- Create `/Users/kogeki/dev/CLIProxyAPI/internal/api/handlers/management/usage_summary.go`: usage summary handler.
- Modify `/Users/kogeki/dev/CLIProxyAPI/internal/api/handlers/management/handler.go`: attach usage ledger dependency to the handler.
- Modify `/Users/kogeki/dev/CLIProxyAPI/internal/api/server.go`: initialize usage ledger and register management routes.
- Modify `/Users/kogeki/dev/CLIProxyAPI/internal/api/handlers/management/opencode_go.go`: append `cpa-usage` to OpenCode Go refresh responses.
- Modify `/Users/kogeki/dev/CLIProxyAPI/internal/api/handlers/management/opencode_go_test.go`: assert `cpa-usage` is present and calculated.
- Modify `/Users/kogeki/dev/CLIProxyAPI/go.mod` and `/Users/kogeki/dev/CLIProxyAPI/go.sum`: add the SQLite driver.

Management repository: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center`

- Create `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/services/api/modelPrices.ts`: model price API client.
- Create `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/services/api/usageSummary.ts`: Codex usage summary API client.
- Create `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/types/usage.ts`: token, price, summary, and window types.
- Create `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/features/modelPrices/ModelPricesPanel.tsx`: model price table/editor.
- Create `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/features/authFiles/components/PasteAuthFileModal.tsx`: pasted JSON auth-file import modal.
- Modify `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/services/api/authFiles.ts`: use raw text upload path for pasted JSON.
- Modify `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/features/authFiles/hooks/useAuthFilesData.ts`: expose pasted import action.
- Modify `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/pages/AuthFilesPage.tsx`: render paste import modal and entry button.
- Modify `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/pages/ConfigPage.tsx` or a suitable admin/settings surface: render model price management.
- Modify `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/pages/QuotaPage.tsx`: render Codex first, OpenCode Go second.
- Modify `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/components/quota/useQuotaLoader.ts` and `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/components/quota/quotaConfigs.ts`: use isolated cache keys and attach Codex usage summary state.
- Modify `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/features/opencodeGo/OpenCodeGoAccountsPanel.tsx`: render backend-provided `cpaUsage`.
- Modify `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/types/opencodeGo.ts` and `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/services/api/opencodeGo.ts`: parse `cpa-usage`.
- Modify `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/i18n/locales/zh-CN.json` and `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/i18n/locales/en.json`: add visible strings.

---

### Task 1: Backend Usage Ledger Types, Pricing, And Windows

**Files:**
- Create: `/Users/kogeki/dev/CLIProxyAPI/internal/usageledger/types.go`
- Create: `/Users/kogeki/dev/CLIProxyAPI/internal/usageledger/pricing.go`
- Create: `/Users/kogeki/dev/CLIProxyAPI/internal/usageledger/window.go`
- Test: `/Users/kogeki/dev/CLIProxyAPI/internal/usageledger/pricing_test.go`
- Test: `/Users/kogeki/dev/CLIProxyAPI/internal/usageledger/window_test.go`

- [ ] **Step 1: Write pricing tests**

Create tests covering normal input/output cost, cache read/write cost, missing model price, exact model match, and `gpt-5*` prefix match.

```go
func TestCostForUsageSeparatesCacheBuckets(t *testing.T) {
	prices := []usageledger.ModelPrice{{
		Model: "gpt-5.5",
		InputPer1M: 10,
		OutputPer1M: 20,
		CacheReadPer1M: 1,
		CacheCreationPer1M: 5,
	}}
	tokens := usageledger.TokenUsage{
		InputTokens: 1000,
		OutputTokens: 2000,
		CacheReadTokens: 300,
		CacheCreationTokens: 100,
	}
	cost, ok, missing := usageledger.CostForUsage("gpt-5.5", tokens, prices)
	if !ok || len(missing) != 0 {
		t.Fatalf("cost missing: ok=%v missing=%v", ok, missing)
	}
	want := float64(600)/1_000_000*10 + float64(2000)/1_000_000*20 + float64(300)/1_000_000*1 + float64(100)/1_000_000*5
	if math.Abs(cost-want) > 0.0000001 {
		t.Fatalf("cost = %v, want %v", cost, want)
	}
}
```

- [ ] **Step 2: Write window tests**

Add tests for `5h`, `7d`, `month`, and reset-at anchored windows.

```go
func TestWindowFromResetAtRollingFiveHour(t *testing.T) {
	resetAt := time.Date(2026, 6, 26, 15, 0, 0, 0, time.UTC)
	window := usageledger.WindowFromReset("5h", resetAt)
	if got := window.Start; !got.Equal(resetAt.Add(-5 * time.Hour)) {
		t.Fatalf("start = %s", got)
	}
	if !window.End.Equal(resetAt) {
		t.Fatalf("end = %s", window.End)
	}
}
```

- [ ] **Step 3: Run tests and verify they fail**

Run:

```bash
go test ./internal/usageledger
```

Expected: package or functions are missing.

- [ ] **Step 4: Implement types and pricing**

Implement these exported types and functions:

```go
type TokenUsage struct {
	InputTokens int64 `json:"input_tokens"`
	OutputTokens int64 `json:"output_tokens"`
	ReasoningTokens int64 `json:"reasoning_tokens"`
	CachedTokens int64 `json:"cached_tokens"`
	CacheReadTokens int64 `json:"cache_read_tokens"`
	CacheCreationTokens int64 `json:"cache_creation_tokens"`
	TotalTokens int64 `json:"total_tokens"`
}

type ModelPrice struct {
	Model string `json:"model"`
	InputPer1M float64 `json:"input_per_1m"`
	OutputPer1M float64 `json:"output_per_1m"`
	CacheReadPer1M float64 `json:"cache_read_per_1m"`
	CacheCreationPer1M float64 `json:"cache_creation_per_1m"`
	CachedPer1M float64 `json:"cached_per_1m,omitempty"`
	Source string `json:"source"`
	UpdatedAt string `json:"updated_at"`
}

func CostForUsage(model string, tokens TokenUsage, prices []ModelPrice) (float64, bool, []string)
func WindowFromReset(kind string, resetAt time.Time) Window
func RollingWindow(kind string, now time.Time) Window
```

- [ ] **Step 5: Run tests and verify they pass**

Run:

```bash
go test ./internal/usageledger
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/usageledger
git commit -m "feat: add usage pricing primitives"
```

---

### Task 2: Backend SQLite Usage Store And Usage Plugin

**Files:**
- Create: `/Users/kogeki/dev/CLIProxyAPI/internal/usageledger/sqlite_store.go`
- Create: `/Users/kogeki/dev/CLIProxyAPI/internal/usageledger/plugin.go`
- Test: `/Users/kogeki/dev/CLIProxyAPI/internal/usageledger/store_test.go`
- Test: `/Users/kogeki/dev/CLIProxyAPI/internal/usageledger/plugin_test.go`
- Modify: `/Users/kogeki/dev/CLIProxyAPI/go.mod`
- Modify: `/Users/kogeki/dev/CLIProxyAPI/go.sum`

- [ ] **Step 1: Add SQLite driver**

Run:

```bash
go get modernc.org/sqlite@latest
```

Expected: `go.mod` includes `modernc.org/sqlite`. If this dependency fails to resolve, stop and use a small JSONL store behind the same `Store` interface for this task, then keep the API unchanged.

- [ ] **Step 2: Write store tests**

Test schema creation, idempotent request ID insertion, hourly/daily rollup updates, summary by window, price CRUD, and 60-day retention.

```go
func TestSQLiteStoreInsertEventUpdatesRollupsOnce(t *testing.T) {
	store := usageledger.MustOpenForTest(t)
	defer store.Close()
	event := usageledger.Event{
		RequestID: "req-1",
		Timestamp: time.Date(2026, 6, 26, 10, 15, 0, 0, time.UTC),
		Provider: "codex",
		Model: "gpt-5.5",
		AuthIndex: "auth-1",
		Tokens: usageledger.TokenUsage{InputTokens: 10, OutputTokens: 5, TotalTokens: 15},
	}
	if inserted, err := store.InsertEvent(context.Background(), event); err != nil || !inserted {
		t.Fatalf("first insert inserted=%v err=%v", inserted, err)
	}
	if inserted, err := store.InsertEvent(context.Background(), event); err != nil || inserted {
		t.Fatalf("second insert inserted=%v err=%v", inserted, err)
	}
	summary, err := store.Summary(context.Background(), usageledger.SummaryFilter{
		Provider: "codex",
		AuthIndex: "auth-1",
		Window: usageledger.Window{Start: event.Timestamp.Add(-time.Hour), End: event.Timestamp.Add(time.Hour)},
	})
	if err != nil {
		t.Fatal(err)
	}
	if summary.Tokens.TotalTokens != 15 || summary.RequestCount != 1 {
		t.Fatalf("summary = %#v", summary)
	}
}
```

Add a second test that proves scoped summaries do not mix credentials:

```go
func TestSQLiteStoreSummaryScopesByAuthIndexAndAPIKeyHash(t *testing.T) {
	store := usageledger.MustOpenForTest(t)
	defer store.Close()
	now := time.Date(2026, 6, 26, 10, 0, 0, 0, time.UTC)
	events := []usageledger.Event{
		{RequestID: "codex-a", Timestamp: now, Provider: "codex", Model: "gpt-5.5", AuthIndex: "codex-auth-1", Tokens: usageledger.TokenUsage{TotalTokens: 10}},
		{RequestID: "codex-b", Timestamp: now, Provider: "codex", Model: "gpt-5.5", AuthIndex: "codex-auth-2", Tokens: usageledger.TokenUsage{TotalTokens: 90}},
		{RequestID: "opencode-a", Timestamp: now, Provider: "opencode-go", Model: "claude-sonnet-4", APIKeyHash: "key-a", AccountRef: "opencode-go:acc-a", Tokens: usageledger.TokenUsage{TotalTokens: 20}},
		{RequestID: "opencode-b", Timestamp: now, Provider: "opencode-go", Model: "claude-sonnet-4", APIKeyHash: "key-b", AccountRef: "opencode-go:acc-b", Tokens: usageledger.TokenUsage{TotalTokens: 80}},
	}
	for _, event := range events {
		if _, err := store.InsertEvent(context.Background(), event); err != nil {
			t.Fatal(err)
		}
	}
	window := usageledger.Window{Start: now.Add(-time.Minute), End: now.Add(time.Minute)}
	codex, err := store.Summary(context.Background(), usageledger.SummaryFilter{Provider: "codex", AuthIndex: "codex-auth-1", Window: window})
	if err != nil {
		t.Fatal(err)
	}
	if codex.Tokens.TotalTokens != 10 {
		t.Fatalf("codex total = %d", codex.Tokens.TotalTokens)
	}
	opencode, err := store.Summary(context.Background(), usageledger.SummaryFilter{Provider: "opencode-go", APIKeyHash: "key-a", AccountRef: "opencode-go:acc-a", Window: window})
	if err != nil {
		t.Fatal(err)
	}
	if opencode.Tokens.TotalTokens != 20 {
		t.Fatalf("opencode total = %d", opencode.Tokens.TotalTokens)
	}
}
```

- [ ] **Step 3: Write plugin tests**

Feed `coreusage.Record` into the plugin and assert normalized provider, auth index, API key hash, tokens, model, request ID, and failed status.

For OpenCode Go records, assert the plugin stores `Provider=opencode-go`, `APIKeyHash=HashAPIKey(record.APIKey)`, and `AccountRef` only when `record.Source` or the caller-provided metadata has an `opencode-go:<account-id>` source. The API key hash is the required fallback for account matching.

- [ ] **Step 4: Run tests and verify they fail**

Run:

```bash
go test ./internal/usageledger
```

Expected: missing store/plugin implementations.

- [ ] **Step 5: Implement store**

Create:

```go
type Store interface {
	InsertEvent(context.Context, Event) (bool, error)
	Summary(context.Context, SummaryFilter) (Summary, error)
	ListModelPrices(context.Context) ([]ModelPrice, error)
	UpsertModelPrice(context.Context, ModelPrice) error
	ReplaceModelPrices(context.Context, []ModelPrice) error
	DeleteModelPrice(context.Context, string) error
	CleanupBefore(context.Context, time.Time) (int64, error)
	Close() error
}
```

SQLite schema must include `usage_events`, `usage_rollups`, and `model_prices`. Enable WAL with `PRAGMA journal_mode=WAL` and `PRAGMA busy_timeout=5000`.

- [ ] **Step 6: Implement plugin**

Create a named plugin registered during server initialization, not package `init`, so tests can isolate it:

```go
func NewPlugin(store Store, clock func() time.Time) coreusage.Plugin
```

Normalize `record.Detail.TotalTokens` using `input + output + reasoning` when absent.

Store these scoping fields on every event and rollup:

```go
Provider string
AuthIndex string
APIKeyHash string
AccountRef string
```

Codex summaries must be able to filter by `Provider + AuthIndex`; OpenCode Go summaries must be able to filter by `Provider + APIKeyHash` and optionally `AccountRef`.

- [ ] **Step 7: Run tests and verify they pass**

Run:

```bash
go test ./internal/usageledger
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add go.mod go.sum internal/usageledger
git commit -m "feat: persist usage rollups"
```

---

### Task 3: Backend Management APIs For Model Prices And Usage Summary

**Files:**
- Create: `/Users/kogeki/dev/CLIProxyAPI/internal/api/handlers/management/model_prices.go`
- Create: `/Users/kogeki/dev/CLIProxyAPI/internal/api/handlers/management/usage_summary.go`
- Test: `/Users/kogeki/dev/CLIProxyAPI/internal/api/handlers/management/model_prices_test.go`
- Test: `/Users/kogeki/dev/CLIProxyAPI/internal/api/handlers/management/usage_summary_test.go`
- Modify: `/Users/kogeki/dev/CLIProxyAPI/internal/api/handlers/management/handler.go`
- Modify: `/Users/kogeki/dev/CLIProxyAPI/internal/api/server.go`

- [ ] **Step 1: Write handler tests**

Test:

```go
func TestModelPricesPatchAndList(t *testing.T)
func TestUsageSummaryUsesExplicitWindow(t *testing.T)
func TestUsageSummaryRejectsInvalidWindow(t *testing.T)
```

Expected JSON fields:

```json
{
  "tokens": {"input_tokens": 10, "output_tokens": 5, "total_tokens": 15},
  "estimated_cost_usd": 0.0002,
  "missing_price_models": [],
  "rows": []
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
go test ./internal/api/handlers/management -run 'Test(ModelPrices|UsageSummary)'
```

Expected: missing methods/routes.

- [ ] **Step 3: Implement handlers**

Add methods:

```go
func (h *Handler) GetModelPrices(c *gin.Context)
func (h *Handler) PutModelPrices(c *gin.Context)
func (h *Handler) PatchModelPrice(c *gin.Context)
func (h *Handler) DeleteModelPrice(c *gin.Context)
func (h *Handler) GetUsageSummary(c *gin.Context)
func (h *Handler) SetUsageLedger(store usageledger.Store)
```

Routes:

```go
mgmt.GET("/model-prices", s.mgmt.GetModelPrices)
mgmt.PUT("/model-prices", s.mgmt.PutModelPrices)
mgmt.PATCH("/model-prices/:model", s.mgmt.PatchModelPrice)
mgmt.DELETE("/model-prices/:model", s.mgmt.DeleteModelPrice)
mgmt.GET("/usage-summary", s.mgmt.GetUsageSummary)
```

- [ ] **Step 4: Initialize ledger in server**

Create the ledger under the config directory, for example:

```go
ledgerPath := filepath.Join(filepath.Dir(configFilePath), "usage-ledger.sqlite")
```

Register:

```go
coreusage.RegisterNamedPlugin("usage-ledger", usageledger.NewPlugin(store, time.Now))
s.mgmt.SetUsageLedger(store)
```

- [ ] **Step 5: Run tests and verify they pass**

Run:

```bash
go test ./internal/api/handlers/management -run 'Test(ModelPrices|UsageSummary)'
go test ./internal/api -run Test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/api internal/usageledger
git commit -m "feat: expose usage summary management api"
```

---

### Task 4: Backend OpenCode Go CPA Usage Composition

**Files:**
- Modify: `/Users/kogeki/dev/CLIProxyAPI/internal/api/handlers/management/opencode_go.go`
- Modify: `/Users/kogeki/dev/CLIProxyAPI/internal/api/handlers/management/opencode_go_test.go`

- [ ] **Step 1: Write OpenCode Go response test**

Extend `TestOpenCodeGoRefreshUsage...` to seed usage events for provider `opencode-go` and the current account API key hash/source. Also seed a second event for another OpenCode Go account under the same provider and assert it is not included. Then assert:

```json
"cpa-usage": {
  "rolling": {"tokens": {"total_tokens": 15}},
  "weekly": {"tokens": {"total_tokens": 15}},
  "monthly": {"tokens": {"total_tokens": 15}}
}
```

- [ ] **Step 2: Run test and verify it fails**

Run:

```bash
go test ./internal/api/handlers/management -run TestOpenCodeGoRefreshUsage
```

Expected: response does not include `cpa-usage`.

- [ ] **Step 3: Implement cpa usage composition**

Add response fields:

```go
type openCodeGoAccountResponse struct {
	...
	CPAUsage *openCodeGoCPAUsageSnapshot `json:"cpa-usage,omitempty"`
}
```

Use `usageledger.WindowFromReset("5h", resetAt)`, `WindowFromReset("7d", resetAt)`, and `WindowFromReset("month", resetAt)` when `reset-at` is present. Query by:

```go
Provider: openCodeGoProviderName(h.cfg.OpenCodeGo)
APIKeyHash: usageledger.HashAPIKey(account.APIKey)
AccountRef: openCodeGoProviderKeySource(account.ID)
```

If `account.APIKey` is empty, return an empty `cpa-usage` snapshot instead of querying the whole provider.

- [ ] **Step 4: Run OpenCode tests**

Run:

```bash
go test ./internal/api/handlers/management -run TestOpenCodeGo
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/api/handlers/management/opencode_go.go internal/api/handlers/management/opencode_go_test.go
git commit -m "feat: include cpa usage in opencode quota"
```

---

### Task 5: Management Model Price UI And API Clients

**Files:**
- Create: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/types/usage.ts`
- Create: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/services/api/modelPrices.ts`
- Create: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/services/api/usageSummary.ts`
- Create: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/features/modelPrices/ModelPricesPanel.tsx`
- Create: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/features/modelPrices/ModelPricesPanel.module.scss`
- Modify: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/services/api/index.ts`
- Modify: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/pages/ConfigPage.tsx`
- Modify: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/i18n/locales/zh-CN.json`
- Modify: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/i18n/locales/en.json`

- [ ] **Step 1: Implement typed API clients**

Add:

```ts
export interface ModelPrice {
  model: string;
  input_per_1m: number;
  output_per_1m: number;
  cache_read_per_1m: number;
  cache_creation_per_1m: number;
  cached_per_1m?: number;
  source?: string;
  updated_at?: string;
}
```

API functions:

```ts
modelPricesApi.list()
modelPricesApi.upsert(model, price)
modelPricesApi.replace(prices)
modelPricesApi.delete(model)
usageSummaryApi.get(params)
```

- [ ] **Step 2: Implement model prices panel**

Render a compact admin table with columns: model, input, output, cache read, cache write, actions. Use inline numeric inputs and save/delete buttons. Validate model is non-empty and prices are finite non-negative numbers.

- [ ] **Step 3: Mount panel in config page**

Place it in the visual/admin settings area near system usage settings. The panel calls the new model prices endpoints and is independent from YAML editing.

- [ ] **Step 4: Run type check**

Run:

```bash
bun run type-check
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/types/usage.ts src/services/api/modelPrices.ts src/services/api/usageSummary.ts src/features/modelPrices src/services/api/index.ts src/pages/ConfigPage.tsx src/i18n/locales
git commit -m "feat: add model price management"
```

---

### Task 6: Management Auth File Pasted JSON Import

**Files:**
- Create: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/features/authFiles/components/PasteAuthFileModal.tsx`
- Modify: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/services/api/authFiles.ts`
- Modify: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/features/authFiles/hooks/useAuthFilesData.ts`
- Modify: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/pages/AuthFilesPage.tsx`
- Modify: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/i18n/locales/zh-CN.json`
- Modify: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/i18n/locales/en.json`

- [ ] **Step 1: Fix raw text upload API**

Change `saveAuthFileText` to call raw upload:

```ts
const saveAuthFileText = async (name: string, text: string) =>
  apiClient.post(`/auth-files?name=${encodeURIComponent(name)}`, text, {
    headers: { 'Content-Type': 'application/json' },
  });
```

- [ ] **Step 2: Add paste modal**

Modal fields:

- file name
- JSON text area
- save/cancel buttons

Validation:

- name ends with `.json`
- name does not include `/` or `\`
- content parses as a JSON object

- [ ] **Step 3: Wire modal into AuthFilesPage**

Add a button beside upload. On success call `loadFiles()` and show success notification.

- [ ] **Step 4: Run type check**

Run:

```bash
bun run type-check
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/services/api/authFiles.ts src/features/authFiles src/pages/AuthFilesPage.tsx src/i18n/locales
git commit -m "feat: paste import auth files"
```

---

### Task 7: Management Quota Ordering, Cache Keys, Codex Usage, And OpenCode CPA Usage

**Files:**
- Modify: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/pages/QuotaPage.tsx`
- Modify: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/components/quota/useQuotaLoader.ts`
- Modify: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/components/quota/quotaConfigs.ts`
- Modify: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/types/opencodeGo.ts`
- Modify: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/services/api/opencodeGo.ts`
- Modify: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/features/opencodeGo/OpenCodeGoAccountsPanel.tsx`
- Modify: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/i18n/locales/zh-CN.json`
- Modify: `/Users/kogeki/dev/Cli-Proxy-API-Management-Center/src/i18n/locales/en.json`

- [ ] **Step 1: Reorder quota page**

Change render order to:

```tsx
<QuotaSection config={CODEX_CONFIG} ... />
<OpenCodeGoAccountsPanel ... />
<QuotaSection config={CLAUDE_CONFIG} ... />
<QuotaSection config={ANTIGRAVITY_CONFIG} ... />
<QuotaSection config={XAI_CONFIG} ... />
<QuotaSection config={KIMI_CONFIG} ... />
```

- [ ] **Step 2: Isolate quota cache keys**

Add a key builder using API base, management key fingerprint, provider type, auth index, and file name. Use it in `useQuotaLoader` instead of `file.name`.

- [ ] **Step 3: Add Codex usage summary**

After Codex quota fetch succeeds, query `usageSummaryApi.get` for `5h`, `7d`, and `month` with `provider=codex` and the current file `auth_index`. Store the summaries in `CodexQuotaState` and render compact token/cost rows below the official quota windows. The UI must not request a summary using only model name, because the same model can exist in multiple auth files.

- [ ] **Step 4: Parse OpenCode `cpa-usage`**

Extend `OpenCodeGoUsageWindow` or add `OpenCodeGoCPAUsageWindow` so `opencodeGoApi.refreshUsage` normalizes `account['cpa-usage']`.

- [ ] **Step 5: Render OpenCode CPA usage**

In each OpenCode window, render official remaining percent first and a small usage line from the backend `cpaUsage` for the same account API key:

```text
CPA: 12.3K token · $0.04
```

Show `未配置价格` when `estimated_cost_usd` is null and token count is non-zero.

- [ ] **Step 6: Run type check**

Run:

```bash
bun run type-check
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/pages/QuotaPage.tsx src/components/quota src/types/opencodeGo.ts src/services/api/opencodeGo.ts src/features/opencodeGo src/i18n/locales
git commit -m "feat: show quota usage costs"
```

---

### Task 8: Full Verification

**Files:**
- Verify both repositories.

- [ ] **Step 1: Run backend tests**

Run:

```bash
go test ./internal/usageledger ./internal/api/handlers/management ./internal/api
```

Expected: PASS.

- [ ] **Step 2: Run backend full test sweep if time allows**

Run:

```bash
go test ./...
```

Expected: PASS or known unrelated failures recorded in final notes.

- [ ] **Step 3: Run management type check and build**

Run:

```bash
bun run type-check
bun run build
```

Expected: PASS.

- [ ] **Step 4: Check git status**

Run in both repos:

```bash
git status --short
```

Expected: only ignored `.codegraph/` or intentional build artifacts remain.

- [ ] **Step 5: Commit final integration fixes**

If verification changes files:

```bash
git add <changed files>
git commit -m "fix: stabilize quota usage integration"
```

---

## Self-Review

- Spec coverage: pasted auth import is Task 6; quota cache and ordering are Task 7; usage ledger, rollups, model prices, and summary are Tasks 1-3; OpenCode server-side composition is Task 4; frontend model prices and usage rendering are Tasks 5 and 7; verification is Task 8.
- Placeholder scan: no deferred implementation markers are intentionally left in this plan.
- Type consistency: backend uses `usageledger.TokenUsage`, `ModelPrice`, `Summary`, and `Window`; frontend uses `ModelPrice`, `UsageSummary`, and OpenCode `cpaUsage` normalized from `cpa-usage`.
