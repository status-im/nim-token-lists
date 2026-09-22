package tkl

import (
	"errors"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestReadersDuringCommits(t *testing.T) {
	h := mustCreate(t)
	var stop atomic.Bool
	var reads atomic.Uint64
	var wg sync.WaitGroup
	for g := 0; g < 64; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			if g%2 == 0 {
				runtime.LockOSThread()
				defer runtime.UnlockOSThread()
			}
			for !stop.Load() {
				page, err := h.GetNative(1)
				if err != nil || len(page.Items) != 1 || page.Items[0].ChainID != 1 {
					t.Errorf("query %+v %v", page, err)
					return
				}
				reads.Add(1)
			}
		}(g)
	}
	for i := 0; i < 100; i++ {
		chains := []uint64{1}
		if i%2 == 0 {
			chains = append(chains, 10)
		}
		if _, err := h.SetChains(chains); err != nil {
			t.Error(err)
			break
		}
	}
	stop.Store(true)
	wg.Wait()
	if reads.Load() == 0 {
		t.Fatal("no readers")
	}
	t.Logf("revision=%d reads=%d", h.Revision(), reads.Load())
}
func TestDestroyWithInflightCalls(t *testing.T) {
	for round := 0; round < 20; round++ {
		h := mustCreate(t)
		var wg sync.WaitGroup
		for g := 0; g < 16; g++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for i := 0; i < 2000; i++ {
					_, err := h.GetAll(0, 0)
					if err == nil {
						continue
					}
					if !errors.Is(err, Closed) && !errors.Is(err, InvalidHandle) {
						t.Errorf("destroy: %v", err)
					}
					return
				}
			}()
		}
		time.Sleep(time.Millisecond)
		if err := h.Destroy(); err != nil {
			t.Fatal(err)
		}
		wg.Wait()
	}
}
