package tkl

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Query output parity: every query's exact output bytes over the embedded
// lists, through a scripted sequence of mutations. Regenerate the golden file
// only from a known-good build with TKL_UPDATE_PARITY=1.

const parityGolden = "testdata/parity.golden"

var parityIDs = []string{"coingecko_arbitrum", "coingecko_base", "coingecko_bsc", "coingecko_ethereum", "coingecko_linea", "coingecko_optimism", "status", "uniswap"}

const (
	weth = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"
	usdc = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
	usdt = "0xdac17f958d2ee523a2206206994597c13d831ec7"
)

type parityRun struct {
	t     *testing.T
	h     *Handle
	lines []string
}

func (r *parityRun) raw(name, op string, input any) []byte {
	rc, body, err := r.h.raw(op, input)
	if err != nil {
		r.t.Fatal(err)
	}
	sum := sha256.Sum256(body)
	r.lines = append(r.lines, fmt.Sprintf("%s rc=%d len=%d %s", name, rc, len(body), hex.EncodeToString(sum[:])))
	return body
}

func (r *parityRun) queries(stage string) {
	q := func(name, op string, input any) []byte {
		return r.raw(stage+"/"+name, op, input)
	}
	all := q("all", "get_all", map[string]any{"offset": 0, "limit": 0})
	q("all-page", "get_all", map[string]any{"offset": 100, "limit": 50})
	q("all-past-end", "get_all", map[string]any{"offset": 1 << 30, "limit": 1})
	byChains := "get_by_chains"
	for _, chain := range []uint64{1, 10, 56, 8453, 42161, 59144, 130, 999} {
		q(fmt.Sprintf("chains-%d", chain), byChains, map[string]any{"chains": []uint64{chain}, "offset": 0, "limit": 0})
	}
	q("chains-multi-page", byChains, map[string]any{"chains": []uint64{56, 10}, "offset": 10, "limit": 20})
	var page Page[Token]
	if err := json.Unmarshal(all, &page); err != nil {
		r.t.Fatal(err)
	}
	keys := []string{"1-" + weth, "1-" + strings.ToUpper(usdc[2:]), "1-" + usdt, "999-" + weth, "10-0x0000000000000000000000000000000000000000"}
	for i := 0; i < len(page.Items); i += 97 {
		keys = append(keys, fmt.Sprintf("%d-%s", page.Items[i].ChainID, page.Items[i].Address))
	}
	byKey := "get_by_key"
	for _, key := range keys {
		q("key-"+key, byKey, map[string]any{"key": key})
	}
	q("key-bad", byKey, map[string]any{"key": "1-0x12"})
	q("keys", "get_by_keys", map[string]any{"keys": append(keys, keys[0])})
	byAddress := "get_by_chain_address"
	for _, address := range []string{weth, strings.ToUpper(usdc), usdt, "0x0000000000000000000000000000000000000000"} {
		for _, chain := range []uint64{1, 56} {
			q(fmt.Sprintf("address-%d-%s", chain, address), byAddress, map[string]any{"chainId": chain, "address": address})
		}
	}
	native := "get_native"
	for _, chain := range []uint64{1, 10, 56, 8453, 42161, 59144, 999} {
		q(fmt.Sprintf("native-%d", chain), native, map[string]any{"chainId": chain})
	}
	list := "get_list"
	for _, id := range append([]string{"native", "custom", "missing"}, parityIDs...) {
		q("list-"+id, list, map[string]any{"id": id})
	}
	q("lists", "get_lists", struct{}{})
	q("diagnostics", "get_diagnostics", struct{}{})
	q("changes", "changes_since", map[string]any{"revision": 0})
}

func parityBodies(t *testing.T) map[string][]byte {
	bodies := map[string][]byte{}
	for _, id := range parityIDs {
		body, err := os.ReadFile(filepath.Join("..", "..", "fixtures", "embedded", id+".json"))
		if err != nil {
			t.Fatal(err)
		}
		bodies[id] = body
	}
	return bodies
}

func parityRegistry() []byte {
	var b strings.Builder
	b.WriteString(`{"timestamp":"2026-01-01T00:00:00Z","version":{"major":1,"minor":0,"patch":0},"tokenLists":[`)
	for i, id := range parityIDs {
		if i > 0 {
			b.WriteString(",")
		}
		schema := ""
		if id == "status" {
			schema = `,"schema":"status"`
		}
		fmt.Fprintf(&b, `{"id":"%s","sourceUrl":"https://example.org/%s"%s}`, id, id, schema)
	}
	b.WriteString("]}")
	return []byte(b.String())
}

func (r *parityRun) refresh(stage string, now int64, bodies map[string][]byte, changed map[string]bool) {
	plan, err := r.h.RefreshPlan(now, true)
	if err != nil {
		r.t.Fatal(err)
	}
	report, err := r.h.RefreshApply(plan.ID, []FetchResult{{ID: "registry", Status: 200, ETag: "r", Body: parityRegistry()}}, now)
	if err != nil || report.Step != "NeedMore" {
		r.t.Fatal(report, err)
	}
	var results []FetchResult
	for _, request := range report.Requests {
		if changed[request.ID] || request.ETag == "" {
			results = append(results, FetchResult{ID: request.ID, Status: 200, ETag: fmt.Sprintf("%s-%d", request.ID, now), Body: bodies[request.ID]})
		} else {
			results = append(results, FetchResult{ID: request.ID, Status: 304})
		}
	}
	ready, err := r.h.RefreshApply(plan.ID, results, now)
	if err != nil || ready.Step != "Ready" {
		r.t.Fatal(ready, err)
	}
	encoded, _ := json.Marshal(ready)
	sum := sha256.Sum256(encoded)
	r.lines = append(r.lines, fmt.Sprintf("%s/report %s", stage, hex.EncodeToString(sum[:])))
	r.raw(stage+"/commit", "refresh_commit",
		map[string]any{"planId": plan.ID, "now": now})
}

func TestQueryOutputParity(t *testing.T) {
	bodies := parityBodies(t)
	config := Config{Chains: []uint64{1, 10, 42161, 8453, 56, 59144}, MainListID: "status", RegistryID: "registry", RegistryURL: "https://example.org/registry"}
	config.Policy.NativeTokens = []Token{{ChainID: 56, Address: "0x0000000000000000000000000000000000000000", CrossChainID: "bsc-native", Name: "BNB", Symbol: "BNB", Decimals: 18}}
	config.Policy.NativeAliases = []Identity{{ChainID: 1, Address: weth}}
	config.Policy.SkippedKeys = []string{"1-" + usdt}
	for _, id := range parityIDs {
		format := StandardFormat
		if id == "status" {
			format = StatusFormat
		}
		config.InitialLists = append(config.InitialLists, ListContent{ID: id, Format: format, Source: "local", FetchedTimestamp: "0001-01-01T00:00:00Z"})
	}
	h, err := Create(config)
	if err != nil {
		t.Fatal(err)
	}
	defer h.Destroy()
	var loads []ListBody
	for _, id := range parityIDs {
		loads = append(loads, ListBody{ID: id, Origin: Bundled, Data: bodies[id]})
	}
	customs := []Token{
		{ChainID: 1, Address: strings.ToUpper("0x00000000000000000000000000000000000000c1"), Symbol: "CUS", Name: "Custom one", Decimals: 6, LogoURI: "https://example.org/c1.png"},
		{ChainID: 10, Address: "0x4200000000000000000000000000000000000006", Symbol: "OWETH", Decimals: 18},
		{ChainID: 777, Address: "0x00000000000000000000000000000000000000c2", Symbol: "BAD", Decimals: 1},
	}
	if _, err = h.LoadStored(Bootstrap{Customs: customs}, loads); err != nil {
		t.Fatal(err)
	}
	r := &parityRun{t: t, h: h}
	r.queries("load")

	r.raw("set-chains", "set_chains",
		map[string]any{"chains": []uint64{1, 10, 8453, 130}})
	r.queries("chains")
	policy := config.Policy
	policy.Priority = "CustomFirstPriority"
	policy.SkippedKeys = []string{"10-0x4200000000000000000000000000000000000006"}
	r.raw("set-policy", "set_policy",
		map[string]any{"policy": policy})
	r.queries("policy")
	mutation, err := h.CustomValidateUpsert(Token{ChainID: 8453, Address: "0x00000000000000000000000000000000000000c3", Symbol: "NEW", Name: "New", Decimals: 9})
	if err != nil {
		t.Fatal(err)
	}
	r.raw("custom-commit", "custom_commit",
		map[string]any{"mutationId": mutation.ID})
	r.queries("custom")

	r.refresh("refresh-all", 100, bodies, nil)
	r.queries("refresh-all")
	edited := map[string][]byte{}
	for id, body := range bodies {
		edited[id] = body
	}
	edited["uniswap"] = []byte(strings.Replace(strings.Replace(string(bodies["uniswap"]), `"symbol": "USDC"`, `"symbol": "USDC.e"`, 1),
		`"name": "Uniswap Labs Default"`, `"name": "Uniswap edited"`, 1))
	r.refresh("refresh-one", 200, edited, map[string]bool{"uniswap": true})
	r.queries("refresh-one")
	r.raw("restore-chains", "set_chains",
		map[string]any{"chains": config.Chains})
	r.queries("restored")

	if os.Getenv("TKL_UPDATE_PARITY") == "1" {
		if err = os.MkdirAll(filepath.Dir(parityGolden), 0o755); err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(parityGolden, []byte(strings.Join(r.lines, "\n")+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	file, err := os.Open(parityGolden)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	var golden []string
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		golden = append(golden, scanner.Text())
	}
	if len(golden) != len(r.lines) {
		t.Fatalf("%d outputs, golden has %d", len(r.lines), len(golden))
	}
	for i := range golden {
		if golden[i] != r.lines[i] {
			t.Errorf("output differs:\n got  %s\n want %s", r.lines[i], golden[i])
		}
	}
}
