package tkl

import (
	"encoding/hex"
	"slices"
	"testing"
)

var mainnets = []uint64{1, 10, 56, 8453, 42161, 59144}

func narrowed(t *testing.T, tokens []Token) []ChainToken {
	t.Helper()
	result := make([]ChainToken, len(tokens))
	for i, token := range tokens {
		address, err := hex.DecodeString(token.Address[2:])
		if err != nil || len(address) != 20 {
			t.Fatal(token.Address, err)
		}
		result[i] = ChainToken{ChainID: token.ChainID, Decimals: token.Decimals}
		copy(result[i].Address[:], address)
	}
	return result
}

func checkPackedParity(t *testing.T, h *Handle, chains []uint64) {
	t.Helper()
	page, err := h.GetByChains(chains, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	request := slices.Clone(chains)
	tokens, revision, err := h.GetByChainsPacked(request, nil)
	if err != nil {
		t.Fatal(err)
	}
	for i := range request {
		request[i] = 999
	}
	if revision != page.Revision || len(tokens) != page.Total {
		t.Fatalf("chains %v: revision %d/%d, count %d/%d", chains, revision, page.Revision, len(tokens), page.Total)
	}
	if want := narrowed(t, page.Items); !slices.Equal(tokens, want) {
		t.Fatalf("chains %v: packed tokens differ from get_by_chains", chains)
	}
}

func TestByChainsPackedParity(t *testing.T) {
	h := loadEmbedded(t, mainnets)
	// Every chain subset is covered by the core and C tests; JSON decoding
	// under -race keeps this to representative sets.
	sets := [][]uint64{nil, mainnets, append(slices.Clone(mainnets), 130, 999), {10, 1, 10}, {56, 59144}}
	for _, chain := range append(slices.Clone(mainnets), 130, 999) {
		sets = append(sets, []uint64{chain})
	}
	check := func() {
		for _, chains := range sets {
			checkPackedParity(t, h, chains)
		}
	}
	check()
	first, err := h.GetByChains([]uint64{1}, 0, 1)
	if err != nil || len(first.Items) != 1 {
		t.Fatal(first, err)
	}
	if _, err = h.SetPolicy(Policy{
		SkippedKeys:   []string{"1-" + first.Items[0].Address, "56-" + usdt},
		NativeAliases: []Identity{{ChainID: 1, Address: "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}},
		NativeTokens:  []Token{{ChainID: 130, Address: "0x0000000000000000000000000000000000000000", Symbol: "ETH", Decimals: 18}},
	}); err != nil {
		t.Fatal(err)
	}
	mutation, err := h.CustomValidateUpsert(Token{ChainID: 10, Address: "0x000000000000000000000000000000000000dead", Symbol: "C", Decimals: 7})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = h.CustomCommit(mutation.ID); err != nil {
		t.Fatal(err)
	}
	if _, err = h.SetChains(append(slices.Clone(mainnets), 130)); err != nil {
		t.Fatal(err)
	}
	check()
	tokens, _, err := h.GetByChainsPacked([]uint64{10}, nil)
	if err != nil || !slices.ContainsFunc(tokens, func(token ChainToken) bool { return token.Decimals == 7 && token.Address[18] == 0xde }) {
		t.Fatal("custom token missing", err)
	}
}

func TestByChainsPackedReusesDestination(t *testing.T) {
	h := loadEmbedded(t, mainnets)
	tokens, _, err := h.GetByChainsPacked(mainnets, nil)
	if err != nil || len(tokens) < 1000 {
		t.Fatal(len(tokens), err)
	}
	fresh := testing.AllocsPerRun(20, func() {
		if _, _, err := h.GetByChainsPacked(mainnets, nil); err != nil {
			t.Fatal(err)
		}
	})
	reused := testing.AllocsPerRun(20, func() {
		again, _, err := h.GetByChainsPacked(mainnets, tokens)
		if err != nil || len(again) != len(tokens) || &again[0] != &tokens[0] {
			t.Fatal("destination not reused", err)
		}
	})
	if fresh > 2 || reused > 1 {
		t.Fatalf("allocs fresh %v reused %v", fresh, reused)
	}
	empty, revision, err := h.GetByChainsPacked(nil, tokens)
	if err != nil || len(empty) != 0 || revision != h.Revision() {
		t.Fatal(len(empty), revision, err)
	}
}

func TestByChainsPackedErrors(t *testing.T) {
	var nilHandle *Handle
	if _, _, err := nilHandle.GetByChainsPacked(mainnets, nil); err != InvalidHandle {
		t.Fatal(err)
	}
	h, err := Create(Config{Chains: []uint64{1}})
	if err != nil {
		t.Fatal(err)
	}
	defer h.Destroy()
	if _, _, err = h.GetByChainsPacked([]uint64{1}, nil); err == nil {
		t.Fatal("unloaded catalogue answered")
	}
}

func BenchmarkByChainsPacked(b *testing.B) {
	h := loadEmbedded(b, mainnets)
	for _, chains := range [][]uint64{mainnets, {1}} {
		b.Run(chainsName(chains), func(b *testing.B) {
			var tokens []ChainToken
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				var err error
				if tokens, _, err = h.GetByChainsPacked(chains, tokens[:0]); err != nil {
					b.Fatal(err)
				}
			}
			b.ReportMetric(float64(len(tokens)), "tokens/op")
		})
	}
}

func BenchmarkByChainsJSON(b *testing.B) {
	h := loadEmbedded(b, mainnets)
	for _, chains := range [][]uint64{mainnets, {1}} {
		b.Run(chainsName(chains), func(b *testing.B) {
			var page Page[Token]
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				var err error
				if page, err = h.GetByChains(chains, 0, 0); err != nil {
					b.Fatal(err)
				}
			}
			b.ReportMetric(float64(page.Total), "tokens/op")
		})
	}
}

func chainsName(chains []uint64) string {
	if len(chains) == 1 {
		return "one-chain"
	}
	return "six-mainnets"
}
