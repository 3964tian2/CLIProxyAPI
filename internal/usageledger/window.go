package usageledger

import (
	"strings"
	"time"
)

// WindowFromReset returns a current usage window ending at resetAt.
func WindowFromReset(kind string, resetAt time.Time) Window {
	if resetAt.IsZero() {
		return Window{}
	}
	return windowEndingAt(normalizeWindowKind(kind), resetAt.UTC())
}

// RollingWindow returns a window ending at now.
func RollingWindow(kind string, now time.Time) Window {
	if now.IsZero() {
		return Window{}
	}
	return windowEndingAt(normalizeWindowKind(kind), now.UTC())
}

func windowEndingAt(kind string, end time.Time) Window {
	switch kind {
	case "5h":
		return Window{Start: end.Add(-5 * time.Hour), End: end}
	case "7d":
		return Window{Start: end.AddDate(0, 0, -7), End: end}
	case "month":
		return Window{Start: end.AddDate(0, -1, 0), End: end}
	default:
		return Window{}
	}
}

func normalizeWindowKind(kind string) string {
	switch strings.ToLower(strings.TrimSpace(kind)) {
	case "rolling", "5h", "five-hour", "five_hour":
		return "5h"
	case "weekly", "7d", "seven-day", "seven_day":
		return "7d"
	case "monthly", "month", "30d":
		return "month"
	default:
		return ""
	}
}
