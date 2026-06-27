package usageledger

const defaultModelPriceSource = "opencode-zen-default"

func defaultModelPrices() []ModelPrice {
	prices := []ModelPrice{
		// OpenCode Zen / GPT and Codex models.
		defaultPrice("gpt-5.5", 5, 30, 0.5, 0, "gpt-5.5"),
		defaultPrice("gpt-5.5-pro", 30, 180, 30, 0, "gpt-5.5-pro"),
		defaultPrice("gpt-5.4", 2.5, 15, 0.25, 0, "gpt-5.4"),
		defaultPrice("gpt-5.4-pro", 30, 180, 30, 0, "gpt-5.4-pro"),
		defaultPrice("gpt-5.4-mini", 0.75, 4.5, 0.075, 0, "gpt-5.4-mini"),
		defaultPrice("gpt-5.4-nano", 0.2, 1.25, 0.02, 0, "gpt-5.4-nano"),
		defaultPrice("gpt-5.3-codex-spark", 1.75, 14, 0.175, 0, "gpt-5.3-codex-spark"),
		defaultPrice("gpt-5.3-codex", 1.75, 14, 0.175, 0, "gpt-5.3-codex"),
		defaultPrice("gpt-5.2", 1.75, 14, 0.175, 0, "gpt-5.2"),
		defaultPrice("gpt-5.2-codex", 1.75, 14, 0.175, 0, "gpt-5.2-codex"),
		defaultPrice("gpt-5.1", 1.07, 8.5, 0.107, 0, "gpt-5.1"),
		defaultPrice("gpt-5.1-codex", 1.07, 8.5, 0.107, 0, "gpt-5.1-codex"),
		defaultPrice("gpt-5.1-codex-max", 1.25, 10, 0.125, 0, "gpt-5.1-codex-max"),
		defaultPrice("gpt-5.1-codex-mini", 0.25, 2, 0.025, 0, "gpt-5.1-codex-mini"),
		defaultPrice("gpt-5", 1.07, 8.5, 0.107, 0, "gpt-5"),
		defaultPrice("gpt-5-codex", 1.07, 8.5, 0.107, 0, "gpt-5-codex"),
		defaultPrice("gpt-5-nano", 0.05, 0.4, 0.005, 0, "gpt-5-nano"),
		defaultPrice("grok-build-0.1", 1, 2, 0.2, 0, "grok-build-0.1"),
		defaultPrice("gpt-image-2", 8, 30, 2, 0, "gpt-image-2"),
		defaultPrice("gpt-image-1.5", 8, 32, 2, 0, "gpt-image-1.5"),

		// OpenCode Go models. Keep both raw and opencode-go/<id> names because
		// clients and providers may report either shape in usage payloads.
		defaultPrice("glm-5.2", 1.4, 4.4, 0.26, 0, "glm-5.2"),
		defaultPrice("glm-5.1", 1.4, 4.4, 0.26, 0, "glm-5.1"),
		defaultPrice("glm-5", 1, 3.2, 0.2, 0, "glm-5"),
		defaultPrice("kimi-k2.7-code", 0.95, 4, 0.19, 0, "kimi-k2.7-code"),
		defaultPrice("kimi-k2.7", 0.95, 4, 0.19, 0, "kimi-k2.7-code"),
		defaultPrice("kimi-k2.6", 0.95, 4, 0.16, 0, "kimi-k2.6"),
		defaultPrice("kimi-k2.5", 0.6, 3, 0.1, 0, "kimi-k2.5"),
		defaultPrice("mimo-v2.5", 0.14, 0.28, 0.0028, 0, "mimo-v2.5"),
		defaultPrice("mimo-v2.5-pro", 1.74, 3.48, 0.0145, 0, "mimo-v2.5-pro"),
		defaultPrice("minimax-m3", 0.3, 1.2, 0.06, 0, "minimax-m3"),
		defaultPrice("minimax-m2.7", 0.3, 1.2, 0.06, 0.375, "minimax-m2.7"),
		defaultPrice("minimax-m2.5", 0.3, 1.2, 0.06, 0.375, "minimax-m2.5"),
		defaultPrice("qwen3.7-max", 2.5, 7.5, 0.5, 3.125, "qwen3.7-max"),
		defaultPrice("qwen3.7-plus", 0.4, 1.6, 0.04, 0.5, "qwen3.7-plus"),
		defaultPrice("qwen3.6-plus", 0.5, 3, 0.05, 0.625, "qwen3.6-plus"),
		defaultPrice("qwen3.5-plus", 0.2, 1.2, 0.02, 0.25, "qwen3.5-plus"),
		defaultPrice("deepseek-v4-pro", 1.74, 3.48, 0.0145, 0, "deepseek-v4-pro"),
		defaultPrice("deepseek-v4-flash", 0.14, 0.28, 0.0028, 0, "deepseek-v4-flash"),
	}

	rawCount := len(prices)
	for i := 0; i < rawCount; i++ {
		price := prices[i]
		if isOpenCodeGoDefaultModel(price.Model) {
			price.Model = "opencode-go/" + price.Model
			prices = append(prices, price)
		}
	}
	return prices
}

func defaultPrice(model string, input, output, cacheRead, cacheCreation float64, sourceModelID string) ModelPrice {
	return ModelPrice{
		Model:              model,
		InputPer1M:         input,
		OutputPer1M:        output,
		CacheReadPer1M:     cacheRead,
		CacheCreationPer1M: cacheCreation,
		CachedPer1M:        cacheRead,
		Source:             defaultModelPriceSource,
		SourceModelID:      sourceModelID,
		UpdatedAt:          "2026-06-25T00:00:00Z",
	}
}

func isOpenCodeGoDefaultModel(model string) bool {
	switch model {
	case "glm-5.2", "glm-5.1", "glm-5", "kimi-k2.7-code", "kimi-k2.7", "kimi-k2.6",
		"kimi-k2.5", "mimo-v2.5", "mimo-v2.5-pro", "minimax-m3", "minimax-m2.7",
		"minimax-m2.5", "qwen3.7-max", "qwen3.7-plus", "qwen3.6-plus",
		"qwen3.5-plus", "deepseek-v4-pro", "deepseek-v4-flash":
		return true
	default:
		return false
	}
}
