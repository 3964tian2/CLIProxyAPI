package usageledger

import (
	"strings"
)

const tokensPerMillion = 1_000_000.0

// CostForUsage computes the estimated USD cost for one model and token set.
func CostForUsage(model string, tokens TokenUsage, prices []ModelPrice) (float64, bool, []string) {
	model = strings.TrimSpace(model)
	price, ok := MatchModelPrice(model, prices)
	if !ok {
		if model == "" {
			model = "unknown"
		}
		return 0, false, []string{model}
	}

	tokens = tokens.Normalize()
	cacheRead := maxInt64(tokens.CacheReadTokens, 0)
	cacheCreation := maxInt64(tokens.CacheCreationTokens, 0)
	compatCached := maxInt64(tokens.CachedTokens-cacheRead-cacheCreation, 0)
	billableInput := maxInt64(tokens.InputTokens-cacheRead-cacheCreation-compatCached, 0)
	output := maxInt64(tokens.OutputTokens+tokens.ReasoningTokens, 0)

	cost := float64(billableInput)/tokensPerMillion*price.InputPer1M +
		float64(output)/tokensPerMillion*price.OutputPer1M +
		float64(cacheRead)/tokensPerMillion*price.CacheReadPer1M +
		float64(cacheCreation)/tokensPerMillion*price.CacheCreationPer1M +
		float64(compatCached)/tokensPerMillion*price.CachedPer1M

	return cost, true, nil
}

// MatchModelPrice resolves an exact model price before a trailing-* wildcard.
func MatchModelPrice(model string, prices []ModelPrice) (ModelPrice, bool) {
	model = strings.TrimSpace(model)
	if model == "" {
		return ModelPrice{}, false
	}
	for _, price := range prices {
		if strings.EqualFold(strings.TrimSpace(price.Model), model) {
			return price, true
		}
	}
	for _, price := range prices {
		pattern := strings.TrimSpace(price.Model)
		if !strings.HasSuffix(pattern, "*") {
			continue
		}
		prefix := strings.TrimSuffix(pattern, "*")
		if prefix != "" && strings.HasPrefix(strings.ToLower(model), strings.ToLower(prefix)) {
			return price, true
		}
	}
	return ModelPrice{}, false
}

func maxInt64(value, minimum int64) int64 {
	if value < minimum {
		return minimum
	}
	return value
}
