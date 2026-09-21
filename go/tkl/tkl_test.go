package tkl

import (
	"bytes"
	"errors"
	"fmt"
	"testing"
)

const twoTokens = `[
 {"chainId":1,"address":"0xAbCdEf0000000000000000000000000000000001","symbol":"AAA","decimals":18},
 {"chainId":10,"address":"0x0000000000000000000000000000000000000000","symbol":"ETH","decimals":18}]`

func mustCreate(t testing.TB) *Handle {
	t.Helper()
	h, err := Create()
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	t.Cleanup(func() { _ = h.Destroy() })
	return h
}

func TestABIVersion(t *testing.T) {
	if got := ABIVersion(); got != 1 {
		t.Fatalf("ABIVersion = %d, want 1", got)
	}
}

func TestStageCommitLookup(t *testing.T) {
	h := mustCreate(t)
	id, err := h.Stage([]byte(twoTokens))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.GetByKey("10-0x0000000000000000000000000000000000000000"); !errors.Is(err, NotFound) {
		t.Fatalf("staged data must be invisible before commit, got %v", err)
	}
	rev, err := h.Commit(id)
	if err != nil || rev != 1 {
		t.Fatalf("Commit = (%d, %v), want (1, nil)", rev, err)
	}
	got, err := h.GetByKey("1-0xABCDEF0000000000000000000000000000000001")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(got, []byte(`"symbol":"AAA"`)) {
		t.Fatalf("unexpected token json: %s", got)
	}
	all, err := h.GetAll()
	if err != nil || !bytes.HasPrefix(all, []byte("[")) {
		t.Fatalf("GetAll = (%s, %v)", all, err)
	}
}

func TestTypedErrors(t *testing.T) {
	h := mustCreate(t)
	if _, err := h.Stage([]byte("nope")); !errors.Is(err, InvalidContent) {
		t.Fatalf("bad json: got %v, want InvalidContent", err)
	}
	if _, err := h.Stage(nil); !errors.Is(err, InvalidArgument) {
		t.Fatalf("nil input: got %v, want InvalidArgument", err)
	}
	if _, err := h.GetByKey("1-0x00000000000000000000000000000000000000ff"); !errors.Is(err, NotFound) {
		t.Fatalf("missing key: got %v, want NotFound", err)
	}
	id, _ := h.Stage([]byte(twoTokens))
	if _, err := h.Stage([]byte(twoTokens)); !errors.Is(err, Busy) {
		t.Fatalf("second stage: got %v, want Busy", err)
	}
	_ = h.Abort(id)
}

func TestStaleHandle(t *testing.T) {
	h, err := Create()
	if err != nil {
		t.Fatal(err)
	}
	if err := h.Destroy(); err != nil {
		t.Fatal(err)
	}
	if err := h.Destroy(); !errors.Is(err, InvalidHandle) {
		t.Fatalf("double destroy: got %v, want InvalidHandle", err)
	}
	if _, err := h.GetAll(); !errors.Is(err, InvalidHandle) {
		t.Fatalf("use after destroy: got %v, want InvalidHandle", err)
	}
}

// --- miniature of the real facade's durable-success ordering (Part A §5.1/§5.3) ---

type contentStore interface{ PutBatch(body []byte) error }

type fakeStore struct {
	fail bool
	rows [][]byte
}

func (s *fakeStore) PutBatch(body []byte) error {
	if s.fail {
		return errors.New("disk full")
	}
	s.rows = append(s.rows, body)
	return nil
}

// applyTokens = stage -> persist -> commit; on persist failure -> abort.
func applyTokens(h *Handle, st contentStore, body []byte) (uint64, error) {
	id, err := h.Stage(body)
	if err != nil {
		return h.Revision(), err
	}
	if err := st.PutBatch(body); err != nil {
		if aerr := h.Abort(id); aerr != nil {
			return h.Revision(), fmt.Errorf("persist: %w; abort: %v", err, aerr)
		}
		return h.Revision(), fmt.Errorf("persist: %w", err)
	}
	return h.Commit(id)
}

func TestPersistFailureLeavesCatalogueUnchanged(t *testing.T) {
	h := mustCreate(t)
	st := &fakeStore{}
	if rev, err := applyTokens(h, st, []byte(twoTokens)); err != nil || rev != 1 {
		t.Fatalf("first apply = (%d, %v)", rev, err)
	}

	st.fail = true
	onlyOne := `[{"chainId":1,"address":"0x00000000000000000000000000000000000000aa","symbol":"NEW","decimals":6}]`
	rev, err := applyTokens(h, st, []byte(onlyOne))
	if err == nil {
		t.Fatal("expected persist error")
	}
	if rev != 1 || h.Revision() != 1 {
		t.Fatalf("revision moved to %d after failed persist", h.Revision())
	}
	if _, err := h.GetByKey("1-0x00000000000000000000000000000000000000aa"); !errors.Is(err, NotFound) {
		t.Fatalf("aborted token became visible: %v", err)
	}
	if _, err := h.GetByKey("1-0xabcdef0000000000000000000000000000000001"); err != nil {
		t.Fatalf("previous catalogue lost: %v", err)
	}

	st.fail = false // recovery: the next apply works, nothing is left staged
	if rev, err := applyTokens(h, st, []byte(onlyOne)); err != nil || rev != 2 {
		t.Fatalf("recovery apply = (%d, %v), want (2, nil)", rev, err)
	}
}
