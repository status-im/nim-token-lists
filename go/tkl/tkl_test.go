package tkl

import (
	"errors"
	"fmt"
	"strings"
	"testing"
)

func mustCreate(t testing.TB) *Handle {
	t.Helper()
	h, err := Create(Config{Chains: []uint64{1, 10}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = h.Destroy() })
	if _, err = h.LoadStored(Bootstrap{}, nil); err != nil {
		t.Fatal(err)
	}
	return h
}
func TestVersionAndErrors(t *testing.T) {
	if ABIVersion() != 3 {
		t.Fatal(ABIVersion())
	}
	if version, err := LibraryVersion(); err != nil || version != "0.3.0" {
		t.Fatal(version, err)
	}
	h := mustCreate(t)
	if _, err := h.LoadStored(Bootstrap{}, nil); !errors.Is(err, Busy) {
		t.Fatal(err)
	}
	if _, err := h.GetByKey("broken"); !errors.Is(err, InvalidArgument) {
		t.Fatal(err)
	}
	if _, err := h.GetAll(-1, 1); !errors.Is(err, InvalidArgument) {
		t.Fatal(err)
	}
	if err := h.Destroy(); err != nil {
		t.Fatal(err)
	}
	if _, err := h.GetAll(0, 0); !errors.Is(err, InvalidHandle) {
		t.Fatal(err)
	}
	if err := h.Destroy(); !errors.Is(err, InvalidHandle) {
		t.Fatal(err)
	}
}
func TestQueriesPoliciesAndCustomPersistence(t *testing.T) {
	h := mustCreate(t)
	const address = "0x0000000000000000000000000000000000000001"
	mutation, err := h.CustomValidateUpsert(Token{ChainID: 1, Address: address, Symbol: "ONE", Decimals: 18})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = h.CustomAbort(mutation.ID); err != nil {
		t.Fatal(err)
	}
	if h.Revision() != 1 {
		t.Fatal("abort published")
	}
	mutation, err = h.CustomValidateUpsert(Token{ChainID: 1, Address: address, Symbol: "ONE", Decimals: 18})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = h.CustomCommit(mutation.ID); err != nil {
		t.Fatal(err)
	}
	hit, err := h.GetByChainAddress(1, address)
	if err != nil || hit.Items[0].Symbol != "ONE" {
		t.Fatal(hit, err)
	}
	page, err := h.GetByKeys([]string{"1-" + address, "1-" + address})
	if err != nil || page.Total != 2 {
		t.Fatal(page, err)
	}
	page, err = h.GetByChains([]uint64{1}, 1, 1)
	if err != nil || page.Total != 2 || len(page.Items) != 1 {
		t.Fatal(page, err)
	}
	native, err := h.GetNative(1)
	if err != nil || native.Items[0].Symbol != "ETH" {
		t.Fatal(native, err)
	}
	lists, err := h.GetLists()
	if err != nil || lists.Total != 2 {
		t.Fatal(lists, err)
	}
	if _, err = h.GetList("custom"); err != nil {
		t.Fatal(err)
	}
	if _, err = h.GetDiagnostics(); err != nil {
		t.Fatal(err)
	}
	if _, err = h.SetPolicy(Policy{SkippedKeys: []string{"1-" + address}}); err != nil {
		t.Fatal(err)
	}
	if _, err = h.GetByKey("1-" + address); !errors.Is(err, NotFound) {
		t.Fatal(err)
	}
	if _, err = h.SetPolicy(Policy{}); err != nil {
		t.Fatal(err)
	}
	mutation, err = h.CustomValidateDelete("1-" + address)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = h.CustomCommit(mutation.ID); err != nil {
		t.Fatal(err)
	}
	if _, err = h.GetByKey("1-" + address); !errors.Is(err, NotFound) {
		t.Fatal(err)
	}
	changes, err := h.ChangesSince(1)
	if err != nil || len(changes.Items) != 4 {
		t.Fatal(changes, err)
	}
}

const registryBody = `{"timestamp":"2026-01-01T00:00:00Z","version":{"major":1,"minor":0,"patch":0},"tokenLists":[{"id":"main","sourceUrl":"https://example.org/main","schema":"standard"}]}`
const listBody = `{"name":"List","timestamp":"2026-01-01T00:00:00Z","version":{"major":1,"minor":0,"patch":0},"tokens":[{"chainId":1,"address":"0x0000000000000000000000000000000000000001","name":"One","symbol":"ONE","decimals":18}]}`

func TestRefreshPersistenceAndSchedule(t *testing.T) {
	h, err := Create(Config{Chains: []uint64{1}, RegistryID: "registry", RegistryURL: "https://example.org/registry"})
	if err != nil {
		t.Fatal(err)
	}
	defer h.Destroy()
	if _, err = h.LoadStored(Bootstrap{}, nil); err != nil {
		t.Fatal(err)
	}
	if _, err = h.SetAutoRefresh(true, 30, 3); err != nil {
		t.Fatal(err)
	}
	if due, err := h.NextDue(10); err != nil || due == nil || *due != 10 {
		t.Fatal(due, err)
	}
	for attempt := 0; attempt < 2; attempt++ {
		now := int64(10 + attempt*10)
		plan, err := h.RefreshPlan(now, true)
		if err != nil {
			t.Fatal(err)
		}
		more, err := h.RefreshApply(plan.ID, []FetchResult{{ID: "registry", Status: 200, Body: []byte(registryBody), ETag: "r1"}}, now+1)
		if err != nil || more.Step != "NeedMore" {
			t.Fatal(more, err)
		}
		ready, err := h.RefreshApply(plan.ID, []FetchResult{{ID: "main", Status: 200, Body: []byte(listBody), ETag: "m1"}}, now+2)
		if err != nil || ready.Step != "Ready" || len(ready.Writes) != 2 {
			t.Fatal(ready, err)
		}
		if h.Revision() != 1 {
			t.Fatal("apply published")
		}
		if attempt == 0 {
			if _, err = h.RefreshAbort(plan.ID, StorageFailure); err != nil {
				t.Fatal(err)
			}
		} else if _, err = h.RefreshCommit(plan.ID, now+3); err != nil {
			t.Fatal(err)
		}
	}
	state, err := h.RefreshState()
	if err != nil || state.LastSuccess != 23 {
		t.Fatal(state, err)
	}
	if _, err = h.SetNetworkAllowed(false); err != nil {
		t.Fatal(err)
	}
	if due, err := h.NextDue(24); err != nil || due != nil {
		t.Fatal(due, err)
	}
	if _, err = h.RefreshPlan(24, true); !errors.Is(err, Aborted) {
		t.Fatal(err)
	}
}
func TestLimitsAndInputIsolation(t *testing.T) {
	limits := Limits{MaxBytes: 128, MaxDepth: 8, MaxArrayItems: 20, MaxObjectMembers: 20, MaxStringBytes: 64}
	h, err := CreateWithLimits(Config{}, &limits)
	if err != nil {
		t.Fatal(err)
	}
	defer h.Destroy()
	if _, err = h.LoadStored(Bootstrap{}, nil); err != nil {
		t.Fatal(err)
	}
	if _, err = h.GetByKey(string(make([]byte, 200))); !errors.Is(err, InvalidArgument) {
		t.Fatal(err)
	}
	if _, err = CreateWithLimits(Config{}, &Limits{}); !errors.Is(err, InvalidArgument) {
		t.Fatal(err)
	}
}

// Bodies are borrowed only for the call that receives them: overwriting a
// buffer after the call returns must not change any result.
func TestBorrowedBodiesCanBeReused(t *testing.T) {
	h, err := Create(Config{Chains: []uint64{1}, MainListID: "main", RegistryID: "registry",
		RegistryURL: "https://example.org/registry", InitialLists: []ListContent{{ID: "main"}}})
	if err != nil {
		t.Fatal(err)
	}
	defer h.Destroy()
	scratch := []byte(strings.Replace(listBody, "ONE", "BND", 2))
	txn, err := h.LoadBegin(Bootstrap{})
	if err != nil {
		t.Fatal(err)
	}
	if err = h.LoadList(txn, "main", Bundled, scratch); err != nil {
		t.Fatal(err)
	}
	overwrite(scratch)
	if _, err = h.LoadFinish(txn); err != nil {
		t.Fatal(err)
	}
	if err = h.LoadList(txn, "main", Bundled, scratch); !errors.Is(err, InvalidArgument) {
		t.Fatal("finished load accepted a body", err)
	}
	expectSymbol(t, h, "BND")
	plan, err := h.RefreshPlan(10, true)
	if err != nil {
		t.Fatal(err)
	}
	scratch = []byte(registryBody)
	if err = h.RefreshPutBody(plan.ID, "registry", scratch); err != nil {
		t.Fatal(err)
	}
	overwrite(scratch)
	more, err := h.RefreshApply(plan.ID, []FetchResult{{ID: "registry", Status: 200, ETag: "r"}}, 13)
	if err != nil || more.Step != "NeedMore" {
		t.Fatal(more, err)
	}
	scratch = []byte(strings.Replace(listBody, "ONE", "NEW", 2))
	results := []FetchResult{{ID: "main", Status: 200, Body: scratch, ETag: "m"}}
	report, err := h.RefreshApply(plan.ID, results, 14)
	overwrite(scratch)
	if err != nil || report.Step != "Ready" || len(report.Writes) != 2 || report.Writes[1].ETag != "m" {
		t.Fatal(report, err)
	}
	if _, err = h.RefreshCommit(plan.ID, 15); err != nil {
		t.Fatal(err)
	}
	expectSymbol(t, h, "NEW")
}

func overwrite(data []byte) {
	for i := range data {
		data[i] = 'x'
	}
}

func expectSymbol(t *testing.T, h *Handle, symbol string) {
	t.Helper()
	page, err := h.GetList("main")
	if err != nil || page.Items[0].Tokens[0].Symbol != symbol {
		t.Fatal(page, err)
	}
}

func TestLoadTransactions(t *testing.T) {
	h, err := Create(Config{Chains: []uint64{1}, MainListID: "main", InitialLists: []ListContent{{ID: "main"}}})
	if err != nil {
		t.Fatal(err)
	}
	defer h.Destroy()
	stored := Bootstrap{Stored: []ListContent{{ID: "main", Source: "https://example.org/main"}}}
	if _, err = h.LoadStored(stored, []ListBody{{ID: "main", Origin: Stored, Data: []byte("broken")}}); !errors.Is(err, InvalidContent) {
		t.Fatal("initial list without a usable body loaded", err)
	}
	if h.Revision() != 0 {
		t.Fatal("failed load published")
	}
	txn, err := h.LoadBegin(stored)
	if err != nil {
		t.Fatal(err)
	}
	if err = h.LoadAbort(txn); err != nil {
		t.Fatal(err)
	}
	if err = h.LoadAbort(txn); !errors.Is(err, InvalidArgument) {
		t.Fatal(err)
	}
	changes, err := h.LoadStored(stored, []ListBody{
		{ID: "main", Origin: Bundled, Data: []byte(strings.Replace(listBody, "ONE", "BND", 2))},
		{ID: "main", Origin: Stored, Data: []byte(listBody)},
	})
	if err != nil || len(changes.Items) != 1 || changes.Items[0].Kind != "BootstrapChange" {
		t.Fatal(changes, err)
	}
	expectSymbol(t, h, "ONE")
}

// Ids with control characters come from fetched registries and must still
// produce valid JSON in every non-query output.
func TestControlCharactersInIdsStayValidJSON(t *testing.T) {
	h, err := Create(Config{Chains: []uint64{1}, MainListID: "main", RegistryID: "registry",
		RegistryURL: "https://example.org/registry", InitialLists: []ListContent{{ID: "main"}}})
	if err != nil {
		t.Fatal(err)
	}
	defer h.Destroy()
	if _, err = h.LoadStored(Bootstrap{}, []ListBody{{ID: "main", Origin: Bundled, Data: []byte(listBody)}}); err != nil {
		t.Fatal(err)
	}
	const odd = "x\u000f\u001f"
	registry := strings.Replace(registryBody, `"schema":"standard"}]`,
		`"schema":"standard"},{"id":"x\u000f\u001f","sourceUrl":"https://example.org/x","schema":"standard"}]`, 1)
	plan, err := h.RefreshPlan(10, true)
	if err != nil {
		t.Fatal(err)
	}
	var unexpected *Error
	if err = h.RefreshPutBody(plan.ID, odd, []byte(listBody)); !errors.As(err, &unexpected) || unexpected.SourceID != odd {
		t.Fatalf("error body: %#v", err)
	}
	more, err := h.RefreshApply(plan.ID, []FetchResult{{ID: "registry", Status: 200, Body: []byte(registry), ETag: "r1"}}, 11)
	if err != nil || len(more.Requests) != 2 || more.Requests[1].ID != odd {
		t.Fatal(more, err)
	}
	ready, err := h.RefreshApply(plan.ID, []FetchResult{{ID: "main", Status: 304},
		{ID: odd, Status: 200, Body: []byte("{}")}}, 12)
	if err != nil || ready.Step != "Ready" || !strings.Contains(fmt.Sprint(ready.Sources), odd) {
		t.Fatal(ready, err)
	}
	if _, err = h.RefreshCommit(plan.ID, 13); err != nil {
		t.Fatal(err)
	}
	changes, err := h.ChangesSince(0)
	if err != nil {
		t.Fatal(changes, err)
	}
	if state, err := h.RefreshState(); err != nil || state.LastSuccess != 13 {
		t.Fatal(state, err)
	}
}
