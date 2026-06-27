package management

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"testing"
	"time"

	"github.com/router-for-me/CLIProxyAPI/v7/internal/config"
	"github.com/router-for-me/CLIProxyAPI/v7/internal/usageledger"
)

func TestUsageSummaryUsesExplicitWindow(t *testing.T) {
	store := openManagementUsageStore(t)
	h := NewHandlerWithoutConfigFilePath(&config.Config{AuthDir: t.TempDir()}, nil)
	h.SetUsageLedger(store)
	router := usageManagementTestRouter(h)

	now := time.Date(2026, 6, 26, 10, 0, 0, 0, time.UTC)
	if err := store.UpsertModelPrice(context.Background(), usageledger.ModelPrice{
		Model:       "gpt-5.5",
		InputPer1M:  10,
		OutputPer1M: 20,
	}); err != nil {
		t.Fatalf("upsert model price: %v", err)
	}
	for _, event := range []usageledger.Event{
		{
			RequestID: "current-auth",
			Timestamp: now,
			Provider:  "codex",
			Model:     "gpt-5.5",
			AuthIndex: "auth-1",
			Tokens:    usageledger.TokenUsage{InputTokens: 10, OutputTokens: 5, TotalTokens: 15},
		},
		{
			RequestID: "other-auth",
			Timestamp: now,
			Provider:  "codex",
			Model:     "gpt-5.5",
			AuthIndex: "auth-2",
			Tokens:    usageledger.TokenUsage{InputTokens: 90, OutputTokens: 90, TotalTokens: 180},
		},
	} {
		if _, err := store.InsertEvent(context.Background(), event); err != nil {
			t.Fatalf("insert event: %v", err)
		}
	}

	query := url.Values{}
	query.Set("provider", "codex")
	query.Set("auth_index", "auth-1")
	query.Set("start", now.Add(-time.Minute).Format(time.RFC3339))
	query.Set("end", now.Add(time.Minute).Format(time.RFC3339))
	rec := performUsageManagementJSON(http.MethodGet, "/v0/management/usage-summary?"+query.Encode(), nil, router)
	if rec.Code != http.StatusOK {
		t.Fatalf("summary status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}

	var summary usageledger.Summary
	if err := json.Unmarshal(rec.Body.Bytes(), &summary); err != nil {
		t.Fatalf("decode summary: %v", err)
	}
	if summary.Tokens.TotalTokens != 15 || summary.RequestCount != 1 {
		t.Fatalf("summary totals = %#v", summary)
	}
	if summary.EstimatedCostUSD == nil || *summary.EstimatedCostUSD != 0.0002 {
		t.Fatalf("estimated cost = %v, want 0.0002", summary.EstimatedCostUSD)
	}
	if len(summary.MissingPriceModels) != 0 {
		t.Fatalf("missing prices = %#v", summary.MissingPriceModels)
	}
}

func TestUsageSummaryRejectsInvalidWindow(t *testing.T) {
	store := openManagementUsageStore(t)
	h := NewHandlerWithoutConfigFilePath(&config.Config{AuthDir: t.TempDir()}, nil)
	h.SetUsageLedger(store)
	router := usageManagementTestRouter(h)

	rec := performUsageManagementJSON(http.MethodGet, "/v0/management/usage-summary?provider=codex&start=bad&end=also-bad", nil, router)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("summary status = %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
}
