package usageledger_test

import (
	"math"
	"testing"

	"github.com/router-for-me/CLIProxyAPI/v7/internal/usageledger"
)

func TestCostForUsageSeparatesCacheBuckets(t *testing.T) {
	prices := []usageledger.ModelPrice{{
		Model:              "gpt-5.5",
		InputPer1M:         10,
		OutputPer1M:        20,
		CacheReadPer1M:     1,
		CacheCreationPer1M: 5,
	}}
	tokens := usageledger.TokenUsage{
		InputTokens:         1000,
		OutputTokens:        2000,
		CacheReadTokens:     300,
		CacheCreationTokens: 100,
	}

	cost, ok, missing := usageledger.CostForUsage("gpt-5.5", tokens, prices)
	if !ok || len(missing) != 0 {
		t.Fatalf("cost missing: ok=%v missing=%v", ok, missing)
	}

	want := float64(600)/1_000_000*10 +
		float64(2000)/1_000_000*20 +
		float64(300)/1_000_000*1 +
		float64(100)/1_000_000*5
	if math.Abs(cost-want) > 0.0000001 {
		t.Fatalf("cost = %v, want %v", cost, want)
	}
}

func TestCostForUsageFallsBackToCachedPerMillion(t *testing.T) {
	prices := []usageledger.ModelPrice{{
		Model:       "legacy-cache-model",
		InputPer1M:  2,
		OutputPer1M: 4,
		CachedPer1M: 0.5,
	}}
	tokens := usageledger.TokenUsage{
		InputTokens:  1000,
		OutputTokens: 1000,
		CachedTokens: 400,
	}

	cost, ok, missing := usageledger.CostForUsage("legacy-cache-model", tokens, prices)
	if !ok || len(missing) != 0 {
		t.Fatalf("cost missing: ok=%v missing=%v", ok, missing)
	}

	want := float64(600)/1_000_000*2 +
		float64(1000)/1_000_000*4 +
		float64(400)/1_000_000*0.5
	if math.Abs(cost-want) > 0.0000001 {
		t.Fatalf("cost = %v, want %v", cost, want)
	}
}

func TestCostForUsageMatchesWildcardAfterExact(t *testing.T) {
	prices := []usageledger.ModelPrice{
		{Model: "gpt-5*", InputPer1M: 1, OutputPer1M: 1},
		{Model: "gpt-5.5", InputPer1M: 10, OutputPer1M: 20},
	}
	tokens := usageledger.TokenUsage{InputTokens: 1_000_000, OutputTokens: 1_000_000}

	exactCost, ok, missing := usageledger.CostForUsage("gpt-5.5", tokens, prices)
	if !ok || len(missing) != 0 {
		t.Fatalf("exact cost missing: ok=%v missing=%v", ok, missing)
	}
	if exactCost != 30 {
		t.Fatalf("exact cost = %v, want 30", exactCost)
	}

	wildcardCost, ok, missing := usageledger.CostForUsage("gpt-5.3-codex-spark", tokens, prices)
	if !ok || len(missing) != 0 {
		t.Fatalf("wildcard cost missing: ok=%v missing=%v", ok, missing)
	}
	if wildcardCost != 2 {
		t.Fatalf("wildcard cost = %v, want 2", wildcardCost)
	}
}

func TestCostForUsageMissingPrice(t *testing.T) {
	cost, ok, missing := usageledger.CostForUsage(
		"missing-model",
		usageledger.TokenUsage{InputTokens: 10, OutputTokens: 20},
		[]usageledger.ModelPrice{{Model: "gpt-5*", InputPer1M: 1}},
	)
	if ok {
		t.Fatalf("ok = true, cost = %v", cost)
	}
	if len(missing) != 1 || missing[0] != "missing-model" {
		t.Fatalf("missing = %#v", missing)
	}
}
