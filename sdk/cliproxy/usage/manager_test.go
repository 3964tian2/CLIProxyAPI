package usage

import (
	"context"
	"testing"
	"time"
)

type usageContextTestKey struct{}

type usageContextCapturePlugin struct {
	ctxs chan context.Context
}

func (p *usageContextCapturePlugin) HandleUsage(ctx context.Context, record Record) {
	p.ctxs <- ctx
}

func TestManagerAddsBoundedDeadlineToPluginContext(t *testing.T) {
	manager := NewManager(1)
	defer manager.Stop()

	plugin := &usageContextCapturePlugin{ctxs: make(chan context.Context, 1)}
	manager.Register(plugin)

	ctx := context.WithValue(context.Background(), usageContextTestKey{}, "request-id")
	manager.Publish(ctx, Record{Model: "gpt-test"})

	var got context.Context
	select {
	case got = <-plugin.ctxs:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for usage plugin context")
	}

	if _, ok := got.Deadline(); !ok {
		t.Fatal("plugin context has no deadline")
	}
	if value := got.Value(usageContextTestKey{}); value != "request-id" {
		t.Fatalf("plugin context value = %v, want request-id", value)
	}
}
