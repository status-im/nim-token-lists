package tkl

import (
	"errors"
	"fmt"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func tokensJSON(n int) []byte {
	b := []byte("[")
	for i := 0; i < n; i++ {
		if i > 0 {
			b = append(b, ',')
		}
		b = append(b, fmt.Sprintf(
			`{"chainId":%d,"address":"0x%040x","symbol":"T%d","decimals":18}`, 1+i%5, i+1, i)...)
	}
	return append(b, ']')
}

// 64 goroutines hammer lookups/bulk reads from arbitrary OS threads while commits swap snapshots.
func TestReadersDuringCommits(t *testing.T) {
	h := mustCreate(t)
	body := tokensJSON(2000)
	id, err := h.Stage(body)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.Commit(id); err != nil {
		t.Fatal(err)
	}

	var stop atomic.Bool
	var reads atomic.Int64
	var wg sync.WaitGroup
	for g := 0; g < 64; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			if g%2 == 0 {
				runtime.LockOSThread() // half pinned, half migrating between threads
				defer runtime.UnlockOSThread()
			}
			key := fmt.Sprintf("%d-0x%040x", 1+g%5, g+1)
			for !stop.Load() {
				if _, err := h.GetByKey(key); err != nil {
					t.Errorf("GetByKey(%s): %v", key, err)
					return
				}
				if g%16 == 0 {
					if _, err := h.GetAll(); err != nil {
						t.Errorf("GetAll: %v", err)
						return
					}
				}
				reads.Add(1)
			}
		}(g)
	}

	deadline := time.Now().Add(3 * time.Second)
	commits := 0
	var worst time.Duration
	for time.Now().Before(deadline) {
		start := time.Now()
		id, err := h.Stage(body)
		if err != nil {
			t.Fatalf("Stage: %v", err)
		}
		if _, err := h.Commit(id); err != nil {
			t.Fatalf("Commit: %v", err)
		}
		if d := time.Since(start); d > worst {
			worst = d
		}
		commits++
	}
	stop.Store(true)
	wg.Wait()

	if got := h.Revision(); got != uint64(commits+1) {
		t.Fatalf("revision = %d, want %d", got, commits+1)
	}
	t.Logf("commits=%d reads=%d worstStageCommit=%s", commits, reads.Load(), worst)
}

// Destroy while calls are in flight: callers must get a typed error, never a crash.
func TestDestroyWithInflightCalls(t *testing.T) {
	for round := 0; round < 50; round++ {
		h, err := Create()
		if err != nil {
			t.Fatal(err)
		}
		id, _ := h.Stage(tokensJSON(500))
		if _, err := h.Commit(id); err != nil {
			t.Fatal(err)
		}
		var wg sync.WaitGroup
		for g := 0; g < 16; g++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for i := 0; i < 2000; i++ {
					_, err := h.GetAll()
					if err == nil {
						continue
					}
					if errors.Is(err, Closed) || errors.Is(err, InvalidHandle) {
						return
					}
					t.Errorf("unexpected error: %v", err)
					return
				}
			}()
		}
		time.Sleep(time.Millisecond)
		if err := h.Destroy(); err != nil {
			t.Fatalf("Destroy: %v", err)
		}
		wg.Wait()
	}
}
