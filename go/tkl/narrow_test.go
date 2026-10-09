package tkl

import (
	"slices"
	"strings"
	"testing"
)

// crossChainIDs returns every distinct cross-chain id of the catalogue.
func crossChainIDs(t testing.TB, all []Token) []string {
	t.Helper()
	var ids []string
	for _, token := range all {
		if token.CrossChainID != "" && !slices.Contains(ids, token.CrossChainID) {
			ids = append(ids, token.CrossChainID)
		}
	}
	if len(ids) < 100 {
		t.Fatal("few cross-chain ids", len(ids))
	}
	return ids
}

func checkCrossChainParity(t *testing.T, h *Handle, all Page[Token], ids []string) {
	t.Helper()
	var want []Token
	for _, token := range all.Items {
		if token.CrossChainID != "" && slices.Contains(ids, token.CrossChainID) {
			want = append(want, token)
		}
	}
	request := slices.Clone(ids)
	tokens, revision, err := h.GetByCrossChainIDsPacked(request, nil)
	if err != nil {
		t.Fatal(err)
	}
	for i := range request {
		request[i] = "overwritten"
	}
	if revision != all.Revision || !slices.Equal(tokens, narrowed(t, want)) {
		t.Fatalf("ids %v: %d tokens, want %d", ids, len(tokens), len(want))
	}
}

func TestByCrossChainIDsPackedParity(t *testing.T) {
	h := loadEmbedded(t, mainnets)
	check := func() {
		all, err := h.GetAll(0, 0)
		if err != nil {
			t.Fatal(err)
		}
		ids := crossChainIDs(t, all.Items)
		sets := [][]string{nil, {}, {""}, {"usd-coin"}, ids, {"tether", "tether", "", "no-such-id", "TETHER"}, {"usd-coin", "ethereum", "status"}}
		for i := 0; i < len(ids); i += 11 {
			sets = append(sets, ids[i:min(len(ids), i+10)])
		}
		for _, set := range sets {
			checkCrossChainParity(t, h, all, set)
		}
	}
	check()
	first, _, err := h.GetByCrossChainIDsPacked([]string{"usd-coin"}, nil)
	if err != nil || len(first) < 3 {
		t.Fatal(len(first), err)
	}
	if _, err = h.SetPolicy(Policy{
		SkippedKeys:   []string{"1-" + usdt},
		NativeAliases: []Identity{{ChainID: 1, Address: "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}},
		NativeTokens:  []Token{{ChainID: 130, Address: "0x0000000000000000000000000000000000000000", Symbol: "ETH", Name: "Ether", Decimals: 18, CrossChainID: "ethereum"}},
	}); err != nil {
		t.Fatal(err)
	}
	mutation, err := h.CustomValidateUpsert(Token{ChainID: 10, Address: "0x000000000000000000000000000000000000dead", Symbol: "C", Name: "C", Decimals: 7, CrossChainID: "usd-coin"})
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
	tokens, _, err := h.GetByCrossChainIDsPacked([]string{"usd-coin", "ethereum"}, nil)
	if err != nil || !slices.ContainsFunc(tokens, func(token ChainToken) bool { return token.ChainID == 130 }) ||
		!slices.ContainsFunc(tokens, func(token ChainToken) bool { return token.Decimals == 7 && token.Address[19] == 0xad }) {
		t.Fatal("native or custom token missing", err)
	}
}

func TestByCrossChainIDsPackedReusesDestination(t *testing.T) {
	h := loadEmbedded(t, mainnets)
	ids := []string{"usd-coin", "tether", "ethereum", "dai", "status"}
	tokens, _, err := h.GetByCrossChainIDsPacked(ids, nil)
	if err != nil || len(tokens) < 10 {
		t.Fatal(len(tokens), err)
	}
	reused := testing.AllocsPerRun(20, func() {
		again, _, err := h.GetByCrossChainIDsPacked(ids, tokens)
		if err != nil || len(again) != len(tokens) || &again[0] != &tokens[0] {
			t.Fatal("destination not reused", err)
		}
	})
	// The request JSON and its encoder state; no allocation per token.
	if reused > 4 {
		t.Fatalf("allocs reused %v", reused)
	}
}

func TestBySymbolOnChainMatchesClientFilter(t *testing.T) {
	h := loadEmbedded(t, mainnets)
	checked := 0
	for _, chain := range []uint64{1, 56, 59144} {
		page, err := h.GetByChains([]uint64{chain}, 0, 0)
		if err != nil {
			t.Fatal(err)
		}
		for i, token := range page.Items {
			if i%17 != 0 {
				continue
			}
			for _, probe := range []string{token.Symbol, strings.ToLower(token.Name), "no-such-symbol"} {
				var want []Token
				for _, candidate := range page.Items {
					if asciiEqualFold(candidate.Symbol, probe) || asciiEqualFold(candidate.Name, probe) {
						want = append(want, candidate)
					}
				}
				got, err := h.GetBySymbolOnChain(chain, probe)
				if err != nil {
					t.Fatal(err)
				}
				if got.Total != len(want) || !slices.EqualFunc(got.Items, want, tokensEqual) || got.Revision != page.Revision {
					t.Fatalf("chain %d %q: %d tokens, want %d", chain, probe, got.Total, len(want))
				}
				checked++
			}
		}
	}
	if checked < 500 {
		t.Fatal("few probes", checked)
	}
	if _, err := h.GetBySymbolOnChain(1, ""); err == nil || !strings.Contains(err.Error(), "InvalidArgument") {
		t.Fatal("empty symbol answered", err)
	}
}

func TestNarrowQueriesErrors(t *testing.T) {
	var nilHandle *Handle
	if _, _, err := nilHandle.GetByCrossChainIDsPacked([]string{"x"}, nil); err != InvalidHandle {
		t.Fatal(err)
	}
	if _, err := nilHandle.GetBySymbolOnChain(1, "x"); err != InvalidHandle {
		t.Fatal(err)
	}
	h, err := Create(Config{Chains: []uint64{1}})
	if err != nil {
		t.Fatal(err)
	}
	defer h.Destroy()
	if _, _, err = h.GetByCrossChainIDsPacked([]string{"x"}, nil); err == nil {
		t.Fatal("unloaded catalogue answered")
	}
	if _, err = h.GetBySymbolOnChain(1, "x"); err == nil {
		t.Fatal("unloaded catalogue answered")
	}
}

// asciiEqualFold is Nim's cmpIgnoreCase(a, b) == 0, which the client uses.
func asciiEqualFold(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i++ {
		x, y := a[i], b[i]
		if 'A' <= x && x <= 'Z' {
			x += 'a' - 'A'
		}
		if 'A' <= y && y <= 'Z' {
			y += 'a' - 'A'
		}
		if x != y {
			return false
		}
	}
	return true
}

func tokensEqual(a, b Token) bool { return a == b }

func BenchmarkByCrossChainIDsPacked(b *testing.B) {
	h := loadEmbedded(b, mainnets)
	all, err := h.GetAll(0, 0)
	if err != nil {
		b.Fatal(err)
	}
	ids := crossChainIDs(b, all.Items)
	for _, set := range []struct {
		name string
		ids  []string
	}{{"five-ids", []string{"usd-coin", "tether", "ethereum", "dai", "status"}}, {"all-ids", ids}} {
		b.Run(set.name, func(b *testing.B) {
			var tokens []ChainToken
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				if tokens, _, err = h.GetByCrossChainIDsPacked(set.ids, tokens[:0]); err != nil {
					b.Fatal(err)
				}
			}
			b.ReportMetric(float64(len(tokens)), "tokens/op")
		})
	}
}

// BenchmarkUniqueTokensCrossChainFilter is what status-go does today: the full
// catalogue as JSON, filtered by cross-chain id in Go.
func BenchmarkUniqueTokensCrossChainFilter(b *testing.B) {
	h := loadEmbedded(b, mainnets)
	ids := []string{"usd-coin", "tether", "ethereum", "dai", "status"}
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		all, err := h.GetAll(0, 0)
		if err != nil {
			b.Fatal(err)
		}
		var keys []string
		for _, token := range all.Items {
			if token.CrossChainID != "" && slices.Contains(ids, token.CrossChainID) {
				keys = append(keys, token.Address)
			}
		}
		if len(keys) == 0 {
			b.Fatal("no tokens")
		}
	}
}

func BenchmarkBySymbolOnChain(b *testing.B) {
	h := loadEmbedded(b, mainnets)
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		page, err := h.GetBySymbolOnChain(1, "usdc")
		if err != nil || page.Total == 0 {
			b.Fatal(page.Total, err)
		}
	}
}

// BenchmarkByChainSymbolFilter is the client's path today: one chain as JSON,
// filtered by symbol or name.
func BenchmarkByChainSymbolFilter(b *testing.B) {
	h := loadEmbedded(b, mainnets)
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		page, err := h.GetByChains([]uint64{1}, 0, 0)
		if err != nil {
			b.Fatal(err)
		}
		found := false
		for _, token := range page.Items {
			if asciiEqualFold(token.Symbol, "usdc") || asciiEqualFold(token.Name, "usdc") {
				found = true
				break
			}
		}
		if !found {
			b.Fatal("not found")
		}
	}
}
