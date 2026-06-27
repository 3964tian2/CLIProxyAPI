package management

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/router-for-me/CLIProxyAPI/v7/internal/usageledger"
)

type modelPricesPayload struct {
	Prices []usageledger.ModelPrice `json:"prices"`
}

// GetModelPrices lists configured model prices.
func (h *Handler) GetModelPrices(c *gin.Context) {
	store, ok := h.requireUsageLedger(c)
	if !ok {
		return
	}
	prices, err := store.ListModelPrices(c.Request.Context())
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, modelPricesPayload{Prices: prices})
}

// PutModelPrices replaces configured model prices.
func (h *Handler) PutModelPrices(c *gin.Context) {
	store, ok := h.requireUsageLedger(c)
	if !ok {
		return
	}
	prices, err := decodeModelPricesPayload(c)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if err := store.ReplaceModelPrices(c.Request.Context(), prices); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

// PatchModelPrice creates or updates one model price. The path model wins.
func (h *Handler) PatchModelPrice(c *gin.Context) {
	store, ok := h.requireUsageLedger(c)
	if !ok {
		return
	}
	var price usageledger.ModelPrice
	if err := c.ShouldBindJSON(&price); err != nil && !errors.Is(err, io.EOF) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid body"})
		return
	}
	price.Model = strings.TrimSpace(c.Param("model"))
	if price.Model == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "model is required"})
		return
	}
	if err := store.UpsertModelPrice(c.Request.Context(), price); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

// DeleteModelPrice deletes one configured model price.
func (h *Handler) DeleteModelPrice(c *gin.Context) {
	store, ok := h.requireUsageLedger(c)
	if !ok {
		return
	}
	model := strings.TrimSpace(c.Param("model"))
	if model == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "model is required"})
		return
	}
	if err := store.DeleteModelPrice(c.Request.Context(), model); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) requireUsageLedger(c *gin.Context) (usageledger.Store, bool) {
	store := h.getUsageLedger()
	if store == nil {
		c.JSON(http.StatusServiceUnavailable, gin.H{"error": "usage ledger is not available"})
		return nil, false
	}
	return store, true
}

func decodeModelPricesPayload(c *gin.Context) ([]usageledger.ModelPrice, error) {
	if c == nil || c.Request == nil || c.Request.Body == nil {
		return nil, errors.New("invalid body")
	}
	data, err := io.ReadAll(c.Request.Body)
	if err != nil {
		return nil, err
	}
	data = []byte(strings.TrimSpace(string(data)))
	if len(data) == 0 {
		return nil, nil
	}

	var wrapped modelPricesPayload
	if err := json.Unmarshal(data, &wrapped); err == nil && wrapped.Prices != nil {
		return wrapped.Prices, nil
	}
	var prices []usageledger.ModelPrice
	if err := json.Unmarshal(data, &prices); err != nil {
		return nil, errors.New("invalid body")
	}
	return prices, nil
}
