package tkl

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

type benchToken struct {
	ChainID  uint64 `json:"chainId"`
	Address  string `json:"address"`
	Symbol   string `json:"symbol"`
	Decimals uint   `json:"decimals"`
}

// ~3 MB of token JSON, the size of wallet_getAllTokens today (Part A §3.3).
const benchTokens = 32000

func benchHandle(b *testing.B) (*Handle, []byte) {
	b.Helper()
	h, err := Create()
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { _ = h.Destroy() })
	body := tokensJSON(benchTokens)
	id, err := h.Stage(body)
	if err != nil {
		b.Fatal(err)
	}
	if _, err := h.Commit(id); err != nil {
		b.Fatal(err)
	}
	return h, body
}

func buildMirror(b testing.TB, h *Handle) map[string]*benchToken {
	raw, err := h.GetAll()
	if err != nil {
		b.Fatal(err)
	}
	var toks []*benchToken
	if err := json.Unmarshal(raw, &toks); err != nil {
		b.Fatal(err)
	}
	m := make(map[string]*benchToken, len(toks))
	for _, t := range toks {
		m[fmt.Sprintf("%d-%s", t.ChainID, strings.ToLower(t.Address))] = t
	}
	return m
}

func BenchmarkLookupCgo(b *testing.B) {
	h, _ := benchHandle(b)
	key := fmt.Sprintf("%d-0x%040x", 1+100%5, 101)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := h.GetByKey(key); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkLookupCgoParallel(b *testing.B) {
	h, _ := benchHandle(b)
	key := fmt.Sprintf("%d-0x%040x", 1+100%5, 101)
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			if _, err := h.GetByKey(key); err != nil {
				b.Error(err)
				return
			}
		}
	})
}

func BenchmarkLookupMirror(b *testing.B) {
	h, _ := benchHandle(b)
	m := buildMirror(b, h)
	key := fmt.Sprintf("%d-0x%040x", 1+100%5, 101)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if m[key] == nil {
			b.Fatal("miss")
		}
	}
}

func BenchmarkGetAllBulk(b *testing.B) {
	h, body := benchHandle(b)
	b.SetBytes(int64(len(body)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := h.GetAll(); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkMirrorRebuild(b *testing.B) {
	h, _ := benchHandle(b)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = buildMirror(b, h)
	}
}

func BenchmarkStageCommit(b *testing.B) {
	h, body := benchHandle(b)
	b.SetBytes(int64(len(body)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		id, err := h.Stage(body)
		if err != nil {
			b.Fatal(err)
		}
		if _, err := h.Commit(id); err != nil {
			b.Fatal(err)
		}
	}
}
