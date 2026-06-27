package usageledger_test

import (
	"testing"
	"time"

	"github.com/router-for-me/CLIProxyAPI/v7/internal/usageledger"
)

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

func TestWindowFromResetAtSevenDay(t *testing.T) {
	resetAt := time.Date(2026, 6, 26, 15, 0, 0, 0, time.UTC)
	window := usageledger.WindowFromReset("7d", resetAt)
	if got := window.Start; !got.Equal(resetAt.AddDate(0, 0, -7)) {
		t.Fatalf("start = %s", got)
	}
	if !window.End.Equal(resetAt) {
		t.Fatalf("end = %s", window.End)
	}
}

func TestWindowFromResetAtMonth(t *testing.T) {
	resetAt := time.Date(2026, 6, 26, 15, 0, 0, 0, time.UTC)
	window := usageledger.WindowFromReset("month", resetAt)
	if got := window.Start; !got.Equal(resetAt.AddDate(0, -1, 0)) {
		t.Fatalf("start = %s", got)
	}
	if !window.End.Equal(resetAt) {
		t.Fatalf("end = %s", window.End)
	}
}

func TestRollingWindowKinds(t *testing.T) {
	now := time.Date(2026, 6, 26, 15, 0, 0, 0, time.UTC)
	tests := []struct {
		kind string
		want time.Time
	}{
		{kind: "5h", want: now.Add(-5 * time.Hour)},
		{kind: "7d", want: now.AddDate(0, 0, -7)},
		{kind: "month", want: now.AddDate(0, -1, 0)},
	}
	for _, tt := range tests {
		t.Run(tt.kind, func(t *testing.T) {
			window := usageledger.RollingWindow(tt.kind, now)
			if !window.Start.Equal(tt.want) {
				t.Fatalf("start = %s, want %s", window.Start, tt.want)
			}
			if !window.End.Equal(now) {
				t.Fatalf("end = %s, want %s", window.End, now)
			}
		})
	}
}

func TestWindowKindRejectsUnknown(t *testing.T) {
	now := time.Date(2026, 6, 26, 15, 0, 0, 0, time.UTC)
	window := usageledger.RollingWindow("unknown", now)
	if !window.IsZero() {
		t.Fatalf("window = %#v, want zero", window)
	}
}
