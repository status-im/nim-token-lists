package tkl

import (
	"errors"
	"strings"
	"testing"
)

func TestProductionCatalogue(t *testing.T) {
	h, err := Create(Config{Chains: []uint64{1}})
	if err != nil {
		t.Fatal(err)
	}
	defer h.Destroy()
	if _, err = h.GetAll(0, 0); !errors.Is(err, InvalidArgument) {
		t.Fatalf("unloaded: %v", err)
	}
	if _, err = h.LoadStored(Bootstrap{}, nil); err != nil {
		t.Fatal(err)
	}
	page, err := h.GetAll(0, 0)
	if err != nil || page.Revision != 1 || page.Total != 1 {
		t.Fatalf("bootstrap: %+v %v", page, err)
	}
	mutation, err := h.CustomValidateUpsert(Token{ChainID: 1, Address: "0x0000000000000000000000000000000000000001", Symbol: "ONE", Decimals: 18})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = h.GetByKey("1-0x0000000000000000000000000000000000000001"); !errors.Is(err, NotFound) {
		t.Fatalf("prepare visible: %v", err)
	}
	if _, err = h.CustomCommit(mutation.ID); err != nil {
		t.Fatal(err)
	}
	token, err := h.GetByKey("1-0x0000000000000000000000000000000000000001")
	if err != nil || token.Items[0].Symbol != "ONE" {
		t.Fatalf("lookup: %+v %v", token, err)
	}
}

func TestLoadChecksDocumentByteLimits(t *testing.T) {
	limits := Limits{MaxBytes: 128, MaxDepth: 8, MaxArrayItems: 20, MaxObjectMembers: 20, MaxStringBytes: 64}
	config := Config{MainListID: "main", InitialLists: []ListContent{{ID: "main"}}}
	document := `{"tokens":[]}`
	for size, ok := range map[int]bool{128: true, 129: false} {
		h, err := CreateWithLimits(config, &limits)
		if err != nil {
			t.Fatal(err)
		}
		body := []byte(document + strings.Repeat(" ", size-len(document)))
		_, err = h.LoadStored(Bootstrap{}, []ListBody{{ID: "main", Origin: Bundled, Data: body}})
		if ok != (err == nil) || (!ok && !errors.Is(err, InvalidArgument)) {
			t.Fatalf("%d byte document: %v", size, err)
		}
		_ = h.Destroy()
	}
}

func TestNoArgumentQueriesSendObjectEnvelopes(t *testing.T) {
	h := mustCreate(t)
	if _, err := h.GetLists(); err != nil {
		t.Fatal(err)
	}
	if _, err := h.GetDiagnostics(); err != nil {
		t.Fatal(err)
	}
	if _, err := h.RefreshState(); err != nil {
		t.Fatal(err)
	}
}

func TestFetchEnvelopeAllowsDocumentsWithinByteLimit(t *testing.T) {
	limits := Limits{MaxBytes: 2048, MaxDepth: 16, MaxArrayItems: 20, MaxObjectMembers: 20, MaxStringBytes: 64}
	h, err := CreateWithLimits(Config{Chains: []uint64{1}, RegistryID: "registry", RegistryURL: "https://example.org/registry"}, &limits)
	if err != nil {
		t.Fatal(err)
	}
	defer h.Destroy()
	if _, err = h.LoadStored(Bootstrap{}, nil); err != nil {
		t.Fatal(err)
	}
	plan, err := h.RefreshPlan(10, true)
	if err != nil {
		t.Fatal(err)
	}
	more, err := h.RefreshApply(plan.ID, []FetchResult{{ID: "registry", Status: 200, Body: []byte(registryBody)}}, 11)
	if err != nil || more.Step != "NeedMore" {
		t.Fatal(more, err)
	}
	ready, err := h.RefreshApply(plan.ID, []FetchResult{{ID: "main", Status: 200, Body: []byte(listBody)}}, 12)
	if err != nil || ready.Step != "Ready" {
		t.Fatal(ready, err)
	}
}
