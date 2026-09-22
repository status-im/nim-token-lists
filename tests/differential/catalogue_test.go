package differential

import (
	"encoding/json"
	"fmt"
	"github.com/status-im/go-wallet-sdk/pkg/tokens/parsers"
	sdk "github.com/status-im/go-wallet-sdk/pkg/tokens/types"
	tkl "github.com/status-im/nim-token-lists/go/tkl"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

var chains = []uint64{1, 10, 8453, 42161}

func read(t testing.TB, path string) string {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}
func sdkList(t testing.TB, body, format string) *sdk.TokenList {
	t.Helper()
	var list *sdk.TokenList
	var err error
	if format == tkl.StatusFormat {
		list, err = (&parsers.StatusTokenListParser{}).Parse([]byte(body), chains)
	} else {
		list, err = (&parsers.StandardTokenListParser{}).Parse([]byte(body), chains)
	}
	if err != nil {
		t.Fatal(err)
	}
	return list
}
func canonical(tokens []tkl.Token) []string {
	out := make([]string, 0, len(tokens))
	for _, token := range tokens {
		body, _ := json.Marshal(token)
		out = append(out, string(body))
	}
	sort.Strings(out)
	return out
}
func converted(list *sdk.TokenList) []tkl.Token {
	out := make([]tkl.Token, 0, len(list.Tokens))
	for _, token := range list.Tokens {
		out = append(out, tkl.Token{ChainID: token.ChainID, Address: strings.ToLower(token.Address.Hex()), CrossChainID: token.CrossChainID,
			Decimals: uint8(token.Decimals), Name: token.Name, Symbol: token.Symbol, LogoURI: token.LogoURI, Custom: token.CustomToken})
	}
	return out
}
func compare(t *testing.T, body, format string) {
	t.Helper()
	expected := sdkList(t, body, format)
	h, err := tkl.Create(tkl.Config{Chains: chains, MainListID: "test", InitialLists: []tkl.ListContent{{ID: "test", Format: format, Body: body}}})
	if err != nil {
		t.Fatal(err)
	}
	defer h.Destroy()
	if _, err = h.LoadStored(tkl.Bootstrap{}); err != nil {
		t.Fatal(err)
	}
	page, err := h.GetList("test")
	if err != nil {
		t.Fatal(err)
	}
	actual := page.Items[0]
	if !reflect.DeepEqual(canonical(actual.Tokens), canonical(converted(expected))) {
		t.Fatalf("token mismatch: Nim=%d SDK=%d", len(actual.Tokens), len(expected.Tokens))
	}
	if actual.Name != expected.Name || actual.Timestamp != expected.Timestamp || actual.LogoURI != expected.LogoURI ||
		actual.Version.Major != int64(expected.Version.Major) || actual.Version.Minor != int64(expected.Version.Minor) || actual.Version.Patch != int64(expected.Version.Patch) {
		t.Fatal("metadata mismatch")
	}
	var tags any
	if err = json.Unmarshal(actual.Tags, &tags); err != nil {
		t.Fatal(err)
	}
	expectedTags := expected.Tags
	if expectedTags == nil {
		expectedTags = map[string]interface{}{}
	}
	if !reflect.DeepEqual(tags, expectedTags) {
		t.Fatal("tags mismatch")
	}
	if strings.Join(actual.Keywords, "\x00") != strings.Join(expected.Keywords, "\x00") {
		t.Fatal("keywords mismatch")
	}
	t.Logf("%d token rows matched", len(actual.Tokens))
}
func TestEmbeddedLists(t *testing.T) {
	files, err := filepath.Glob("../../fixtures/embedded/*.json")
	if err != nil || len(files) != 8 {
		t.Fatal(files, err)
	}
	for _, file := range files {
		t.Run(filepath.Base(file), func(t *testing.T) {
			format := tkl.StandardFormat
			if filepath.Base(file) == "status.json" {
				format = tkl.StatusFormat
			}
			compare(t, read(t, file), format)
		})
	}
}
func TestPortedTokenFixtures(t *testing.T) {
	files, err := filepath.Glob("../../fixtures/sdk/*/*tokens*response*.json")
	if err != nil {
		t.Fatal(err)
	}
	template := read(t, "../../fixtures/sdk/parsers/status_token_list_response_template.json")
	for _, file := range files {
		t.Run(filepath.Base(filepath.Dir(file))+"/"+filepath.Base(file), func(t *testing.T) {
			rows := read(t, file)
			body := strings.NewReplacer("NAME", "Fixture List", "TIMESTAMP", "2025-09-01T00:00:00.000Z", "MAJOR", "1", "MINOR", "2", "TOKENS", rows).Replace(template)
			format := tkl.StandardFormat
			if strings.HasPrefix(filepath.Base(file), "status_") {
				format = tkl.StatusFormat
			}
			compare(t, body, format)
		})
	}
}
func TestCompleteCatalogue(t *testing.T) {
	files, _ := filepath.Glob("../../fixtures/embedded/*.json")
	config := tkl.Config{Chains: chains, MainListID: "status"}
	expected := map[string]tkl.Token{}
	// Native tokens and first-source precedence are separate from parser parity.
	for _, chain := range chains {
		expected[fmt.Sprintf("%d-0x%040x", chain, 0)] = tkl.Token{ChainID: chain, Address: fmt.Sprintf("0x%040x", 0), Symbol: "ETH", Name: "Ethereum", CrossChainID: "eth-native", Decimals: 18,
			LogoURI: "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2/logo.png"}
	}
	sort.Slice(files, func(i, j int) bool {
		if filepath.Base(files[i]) == "status.json" {
			return true
		}
		if filepath.Base(files[j]) == "status.json" {
			return false
		}
		return files[i] < files[j]
	})
	for _, file := range files {
		id := strings.TrimSuffix(filepath.Base(file), ".json")
		format := tkl.StandardFormat
		if id == "status" {
			format = tkl.StatusFormat
		}
		body := read(t, file)
		config.InitialLists = append(config.InitialLists, tkl.ListContent{ID: id, Format: format, Body: body})
		for _, token := range converted(sdkList(t, body, format)) {
			key := fmt.Sprintf("%d-%s", token.ChainID, token.Address)
			if _, exists := expected[key]; !exists {
				expected[key] = token
			}
		}
	}
	h, err := tkl.Create(config)
	if err != nil {
		t.Fatal(err)
	}
	defer h.Destroy()
	if _, err = h.LoadStored(tkl.Bootstrap{}); err != nil {
		t.Fatal(err)
	}
	all, err := h.GetAll(0, 0)
	if err != nil {
		t.Fatal(err)
	}
	var want []tkl.Token
	for _, token := range expected {
		want = append(want, token)
	}
	if !reflect.DeepEqual(canonical(all.Items), canonical(want)) {
		t.Fatalf("catalogue mismatch Nim=%d SDK=%d", len(all.Items), len(want))
	}
	if all.Total != 8404 {
		t.Fatalf("golden count %d", all.Total)
	}
	t.Logf("%d unique catalogue tokens matched", all.Total)
}

func TestRegistryFixtures(t *testing.T) {
	files, _ := filepath.Glob("../../fixtures/sdk/fetcher/token_lists_response*.json")
	files = append(files, "../../fixtures/sdk/fetcher/list_of_token_lists_some_wrong_urls_response.json")
	template := read(t, "../../fixtures/sdk/fetcher/list_of_token_lists_response_template.json")
	for _, file := range files {
		t.Run(filepath.Base(file), func(t *testing.T) {
			body := strings.NewReplacer("TIMESTAMP", "2025-09-01T00:00:00.000Z", "MINOR", "2", "TOKEN_LISTS", read(t, file)).Replace(template)
			body = strings.ReplaceAll(body, "SERVER-URL", "https://example.org")
			reference, err := (&parsers.StatusListOfTokenListsParser{}).Parse([]byte(body))
			if err != nil {
				t.Fatal(err)
			}
			h, err := tkl.Create(tkl.Config{Chains: chains, RegistryID: "registry", RegistryURL: "https://example.org/registry"})
			if err != nil {
				t.Fatal(err)
			}
			defer h.Destroy()
			if _, err = h.LoadStored(tkl.Bootstrap{}); err != nil {
				t.Fatal(err)
			}
			plan, err := h.RefreshPlan(10, true)
			if err != nil {
				t.Fatal(err)
			}
			report, err := h.RefreshApply(plan.ID, []tkl.FetchResult{{ID: "registry", Status: 200, Body: body}}, 11)
			if err != nil || len(report.Requests) != len(reference.TokenLists) {
				t.Fatal(report, err)
			}
			for i, source := range reference.TokenLists {
				if report.Requests[i].ID != source.ID || report.Requests[i].URL != source.SourceURL {
					t.Fatal("registry request mismatch")
				}
			}
		})
	}
}

func TestSchemaFixturesRemainData(t *testing.T) {
	files, _ := filepath.Glob("../../fixtures/sdk/fetcher/*schema*.json")
	for _, file := range files {
		t.Run(filepath.Base(file), func(t *testing.T) {
			registry := map[string]any{"timestamp": "2026-01-01T00:00:00Z", "version": map[string]int{"major": 1, "minor": 0, "patch": 0},
				"tokenLists": []any{map[string]any{"id": "remote", "sourceUrl": "https://example.org/list", "schema": read(t, file)}}}
			body, _ := json.Marshal(registry)
			h, err := tkl.Create(tkl.Config{RegistryID: "registry", RegistryURL: "https://example.org/registry"})
			if err != nil {
				t.Fatal(err)
			}
			defer h.Destroy()
			if _, err = h.LoadStored(tkl.Bootstrap{}); err != nil {
				t.Fatal(err)
			}
			plan, err := h.RefreshPlan(10, true)
			if err != nil {
				t.Fatal(err)
			}
			report, err := h.RefreshApply(plan.ID, []tkl.FetchResult{{ID: "registry", Status: 200, Body: string(body)}}, 11)
			if err != nil || report.Step != "Ready" || len(report.Sources) != 2 || report.Sources[1].Outcome != "UnsupportedSchema" {
				t.Fatal(report, err)
			}
		})
	}
}
