package tkl

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func benchmarkCatalogue(b *testing.B) *Handle {
	h := loadEmbedded(b, []uint64{1, 10, 8453, 42161})
	all, err := h.GetAll(0, 0)
	if err != nil || all.Total != 8404 {
		b.Fatal(all.Total, err)
	}
	return h
}

// loadEmbedded loads the eight embedded lists with chains enabled.
func loadEmbedded(tb testing.TB, chains []uint64) *Handle {
	tb.Helper()
	files, err := filepath.Glob("../../fixtures/embedded/*.json")
	if err != nil || len(files) != 8 {
		tb.Fatal(files, err)
	}
	config := Config{Chains: chains, MainListID: "status"}
	var bodies []ListBody
	for _, file := range files {
		body, err := os.ReadFile(file)
		if err != nil {
			tb.Fatal(err)
		}
		id := strings.TrimSuffix(filepath.Base(file), ".json")
		format := StandardFormat
		if id == "status" {
			format = StatusFormat
		}
		config.InitialLists = append(config.InitialLists, ListContent{ID: id, Format: format})
		bodies = append(bodies, ListBody{ID: id, Origin: Bundled, Data: body})
	}
	h, err := Create(config)
	if err != nil {
		tb.Fatal(err)
	}
	tb.Cleanup(func() { _ = h.Destroy() })
	if _, err = h.LoadStored(Bootstrap{}, bodies); err != nil {
		tb.Fatal(err)
	}
	return h
}

func BenchmarkLookup(b *testing.B) {
	h := benchmarkCatalogue(b)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := h.GetNative(1); err != nil {
			b.Fatal(err)
		}
	}
}
func BenchmarkCustomPrepareCommit(b *testing.B) {
	h := benchmarkCatalogue(b)
	token := Token{ChainID: 1, Address: "0x0000000000000000000000000000000000000001", Symbol: "ONE", Decimals: 18}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		m, err := h.CustomValidateUpsert(token)
		if err != nil {
			b.Fatal(err)
		}
		if _, err = h.CustomCommit(m.ID); err != nil {
			b.Fatal(err)
		}
	}
}

// This measures the complete bulk transfer and typed decode needed to refresh
// a host mirror, using the same eight-list catalogue as the lookup benchmark.
func BenchmarkGetAllBulk(b *testing.B) {
	h := benchmarkCatalogue(b)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		page, err := h.GetAll(0, 0)
		if err != nil || page.Total != 8404 {
			b.Fatal(page.Total, err)
		}
	}
	b.ReportMetric(8404, "tokens/op")
}
