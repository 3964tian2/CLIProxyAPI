package management

import (
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/router-for-me/CLIProxyAPI/v7/internal/usageledger"
)

// GetUsageSummary returns scoped token and cost usage for a window.
func (h *Handler) GetUsageSummary(c *gin.Context) {
	store, ok := h.requireUsageLedger(c)
	if !ok {
		return
	}
	filter, err := usageSummaryFilterFromQuery(c)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	summary, err := store.Summary(c.Request.Context(), filter)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, summary)
}

func usageSummaryFilterFromQuery(c *gin.Context) (usageledger.SummaryFilter, error) {
	provider := strings.TrimSpace(c.Query("provider"))
	if provider == "" {
		return usageledger.SummaryFilter{}, errBadUsageSummaryWindow("provider is required")
	}
	window, err := usageSummaryWindowFromQuery(c)
	if err != nil {
		return usageledger.SummaryFilter{}, err
	}
	return usageledger.SummaryFilter{
		Provider:   provider,
		Model:      strings.TrimSpace(c.Query("model")),
		AuthIndex:  firstNonEmptyUsageSummaryQuery(c.Query("auth_index"), c.Query("authIndex")),
		APIKeyHash: firstNonEmptyUsageSummaryQuery(c.Query("api_key_hash"), c.Query("apiKeyHash")),
		AccountRef: firstNonEmptyUsageSummaryQuery(c.Query("account_ref"), c.Query("accountRef")),
		Window:     window,
	}, nil
}

func usageSummaryWindowFromQuery(c *gin.Context) (usageledger.Window, error) {
	startRaw := strings.TrimSpace(c.Query("start"))
	endRaw := strings.TrimSpace(c.Query("end"))
	if startRaw != "" || endRaw != "" {
		start, err := parseUsageSummaryTime(startRaw)
		if err != nil {
			return usageledger.Window{}, errBadUsageSummaryWindow("invalid start")
		}
		end, err := parseUsageSummaryTime(endRaw)
		if err != nil {
			return usageledger.Window{}, errBadUsageSummaryWindow("invalid end")
		}
		window := usageledger.Window{Start: start, End: end}
		if window.IsZero() {
			return usageledger.Window{}, errBadUsageSummaryWindow("invalid window")
		}
		return window, nil
	}

	kind := strings.TrimSpace(c.Query("window"))
	if kind == "" {
		kind = strings.TrimSpace(c.Query("kind"))
	}
	resetAtRaw := strings.TrimSpace(firstNonEmptyUsageSummaryQuery(c.Query("reset_at"), c.Query("resetAt")))
	if resetAtRaw != "" {
		resetAt, err := parseUsageSummaryTime(resetAtRaw)
		if err != nil {
			return usageledger.Window{}, errBadUsageSummaryWindow("invalid reset_at")
		}
		window := usageledger.WindowFromReset(kind, resetAt)
		if window.IsZero() {
			return usageledger.Window{}, errBadUsageSummaryWindow("invalid window")
		}
		return window, nil
	}
	if kind != "" {
		window := usageledger.RollingWindow(kind, time.Now())
		if window.IsZero() {
			return usageledger.Window{}, errBadUsageSummaryWindow("invalid window")
		}
		return window, nil
	}
	return usageledger.Window{}, errBadUsageSummaryWindow("start/end or window is required")
}

func parseUsageSummaryTime(raw string) (time.Time, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return time.Time{}, errBadUsageSummaryWindow("empty time")
	}
	parsed, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil {
		return time.Time{}, err
	}
	return parsed.UTC(), nil
}

type errBadUsageSummaryWindow string

func (e errBadUsageSummaryWindow) Error() string {
	return string(e)
}

func firstNonEmptyUsageSummaryQuery(values ...string) string {
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" {
			return value
		}
	}
	return ""
}
