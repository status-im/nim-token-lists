// Package tkl calls the Nim token catalogue exclusively through its versioned C ABI.
// Callers provide include/library paths via CGO_CFLAGS and CGO_LDFLAGS.
package tkl

/*
#cgo LDFLAGS: -ltkl
#cgo linux LDFLAGS: -lm -lpthread
#include "tkl.h"
*/
import "C"
import (
	"encoding/json"
	"fmt"
	"unsafe"
)

type Status int32

const (
	Ok                Status = 0
	NotFound          Status = 1
	Unchanged         Status = 2
	Aborted           Status = 3
	SupersededPlan    Status = 4
	Busy              Status = 5
	PartialSuccess    Status = 6
	InvalidContent    Status = 7
	UnsupportedSchema Status = 8
	UnsupportedChain  Status = 9
	ValidationFailed  Status = 10
	NetworkFailure    Status = 11
	StorageFailure    Status = 12
	InvalidArgument   Status = 13
	InvalidHandle     Status = 14
	Closed            Status = 15
	AbiMismatch       Status = 16
	Internal          Status = 17
)

var statusNames = [...]string{"Ok", "NotFound", "Unchanged", "Aborted", "SupersededPlan", "Busy", "PartialSuccess", "InvalidContent", "UnsupportedSchema", "UnsupportedChain", "ValidationFailed", "NetworkFailure", "StorageFailure", "InvalidArgument", "InvalidHandle", "Closed", "AbiMismatch", "Internal"}

func (s Status) Error() string {
	if s >= 0 && int(s) < len(statusNames) {
		return "tkl: " + statusNames[s]
	}
	return fmt.Sprintf("tkl: status %d", s)
}

type Error struct {
	Code             Status
	Detail, SourceID string
}

func (e *Error) Error() string        { return fmt.Sprintf("%s: %s (%s)", e.Code, e.Detail, e.SourceID) }
func (e *Error) Is(target error) bool { s, ok := target.(Status); return ok && s == e.Code }

// Handle is safe for concurrent calls. Hosts serialize persistence and commit
// against other mutations; neither Go nor Nim retains host byte pointers.
type Handle struct{ h C.uint64_t }

func ABIVersion() uint32 { return uint32(C.tkl_abi_version()) }
func takeBuf(buf *C.TklBuf) []byte {
	defer C.tkl_buf_free(buf)
	if buf.data == nil || buf.len == 0 {
		return nil
	}
	if uint64(buf.len) > uint64(^uint(0)>>1) {
		panic("tkl: buffer exceeds address space")
	}
	return append([]byte(nil), unsafe.Slice((*byte)(unsafe.Pointer(buf.data)), int(buf.len))...)
}
func statusError(rc C.int32_t, body []byte) error {
	if rc == 0 {
		return nil
	}
	var detail Diagnostic
	_ = json.Unmarshal(body, &detail)
	return &Error{Code: Status(rc), Detail: detail.Detail, SourceID: detail.SourceID}
}
func Create(config Config) (*Handle, error) { return CreateWithLimits(config, nil) }
func CreateWithLimits(config Config, limits *Limits) (*Handle, error) {
	input, err := json.Marshal(struct {
		Config Config  `json:"config"`
		Limits *Limits `json:"limits,omitempty"`
	}{config, limits})
	if err != nil {
		return nil, err
	}
	var h C.uint64_t
	var buf C.TklBuf
	rc := C.tkl_create(C.TKL_ABI_VERSION, (*C.char)(unsafe.Pointer(unsafe.SliceData(input))), C.size_t(len(input)), &h, &buf)
	if err = statusError(rc, takeBuf(&buf)); err != nil {
		return nil, err
	}
	return &Handle{h: h}, nil
}
func LibraryVersion() (string, error) {
	var buf C.TklBuf
	rc := C.tkl_lib_version(&buf)
	body := takeBuf(&buf)
	if err := statusError(rc, body); err != nil {
		return "", err
	}
	var version string
	err := json.Unmarshal(body, &version)
	return version, err
}
func (h *Handle) Destroy() error {
	if h == nil {
		return InvalidHandle
	}
	return statusError(C.tkl_destroy(h.h), nil)
}
func (h *Handle) Revision() uint64 {
	if h == nil {
		return 0
	}
	return uint64(C.tkl_revision(h.h))
}
func (h *Handle) call(operation string, input any) ([]byte, error) {
	if h == nil {
		return nil, InvalidHandle
	}
	data, err := json.Marshal(input)
	if err != nil {
		return nil, err
	}
	var out C.TklBuf
	p := (*C.char)(unsafe.Pointer(unsafe.SliceData(data)))
	n := C.size_t(len(data))
	var rc C.int32_t
	switch operation {
	case "load_stored":
		rc = C.tkl_load_stored(h.h, p, n, &out)
	case "set_chains":
		rc = C.tkl_set_chains(h.h, p, n, &out)
	case "set_policy":
		rc = C.tkl_set_policy(h.h, p, n, &out)
	case "get_by_key":
		rc = C.tkl_get_by_key(h.h, p, n, &out)
	case "get_by_chain_address":
		rc = C.tkl_get_by_chain_address(h.h, p, n, &out)
	case "get_by_keys":
		rc = C.tkl_get_by_keys(h.h, p, n, &out)
	case "get_by_chains":
		rc = C.tkl_get_by_chains(h.h, p, n, &out)
	case "get_all":
		rc = C.tkl_get_all(h.h, p, n, &out)
	case "get_native":
		rc = C.tkl_get_native(h.h, p, n, &out)
	case "get_list":
		rc = C.tkl_get_list(h.h, p, n, &out)
	case "get_lists":
		rc = C.tkl_get_lists(h.h, p, n, &out)
	case "get_diagnostics":
		rc = C.tkl_get_diagnostics(h.h, p, n, &out)
	case "custom_validate_upsert":
		rc = C.tkl_custom_validate_upsert(h.h, p, n, &out)
	case "custom_validate_delete":
		rc = C.tkl_custom_validate_delete(h.h, p, n, &out)
	case "custom_commit":
		rc = C.tkl_custom_commit(h.h, p, n, &out)
	case "custom_abort":
		rc = C.tkl_custom_abort(h.h, p, n, &out)
	case "refresh_plan":
		rc = C.tkl_refresh_plan(h.h, p, n, &out)
	case "refresh_apply":
		rc = C.tkl_refresh_apply(h.h, p, n, &out)
	case "refresh_commit":
		rc = C.tkl_refresh_commit(h.h, p, n, &out)
	case "refresh_abort":
		rc = C.tkl_refresh_abort(h.h, p, n, &out)
	case "set_auto_refresh":
		rc = C.tkl_set_auto_refresh(h.h, p, n, &out)
	case "set_network_allowed":
		rc = C.tkl_set_network_allowed(h.h, p, n, &out)
	case "next_due":
		rc = C.tkl_next_due(h.h, p, n, &out)
	case "changes_since":
		rc = C.tkl_changes_since(h.h, p, n, &out)
	case "refresh_state":
		rc = C.tkl_refresh_state(h.h, p, n, &out)
	default:
		return nil, InvalidArgument
	}
	body := takeBuf(&out)
	if err = statusError(rc, body); err != nil {
		return nil, err
	}
	return body, nil
}
func call[T any](h *Handle, operation string, input any) (T, error) {
	var result T
	body, err := h.call(operation, input)
	if err != nil {
		return result, err
	}
	err = json.Unmarshal(body, &result)
	return result, err
}

func (h *Handle) LoadStored(bootstrap Bootstrap) (Page[Change], error) {
	return call[Page[Change]](h, "load_stored", bootstrap)
}

func (h *Handle) GetAll(offset, limit int) (Page[Token], error) {
	return call[Page[Token]](h, "get_all", map[string]any{"offset": offset, "limit": limit})
}

func (h *Handle) GetByKey(key string) (Page[Token], error) {
	return call[Page[Token]](h, "get_by_key", map[string]any{"key": key})
}

func (h *Handle) GetByChainAddress(chainID uint64, address string) (Page[Token], error) {
	return call[Page[Token]](h, "get_by_chain_address", map[string]any{"chainId": chainID, "address": address})
}

func (h *Handle) GetNative(chainID uint64) (Page[Token], error) {
	return call[Page[Token]](h, "get_native", map[string]any{"chainId": chainID})
}

func (h *Handle) GetByKeys(keys []string) (Page[Token], error) {
	return call[Page[Token]](h, "get_by_keys", struct {
		Keys []string `json:"keys,omitempty"`
	}{keys})
}

func (h *Handle) GetByChains(chains []uint64, offset, limit int) (Page[Token], error) {
	return call[Page[Token]](h, "get_by_chains", struct {
		Chains []uint64 `json:"chains,omitempty"`
		Offset int      `json:"offset"`
		Limit  int      `json:"limit"`
	}{chains, offset, limit})
}

func (h *Handle) GetList(id string) (Page[TokenList], error) {
	return call[Page[TokenList]](h, "get_list", map[string]any{"id": id})
}

func (h *Handle) GetLists() (Page[TokenList], error) {
	return call[Page[TokenList]](h, "get_lists", struct{}{})
}

func (h *Handle) GetDiagnostics() (Page[Diagnostic], error) {
	return call[Page[Diagnostic]](h, "get_diagnostics", struct{}{})
}

func (h *Handle) SetChains(chains []uint64) (Change, error) {
	return call[Change](h, "set_chains", struct {
		Chains []uint64 `json:"chains,omitempty"`
	}{chains})
}

func (h *Handle) SetPolicy(policy Policy) (Change, error) {
	return call[Change](h, "set_policy", map[string]any{"policy": policy})
}

func (h *Handle) CustomValidateUpsert(token Token) (Mutation, error) {
	return call[Mutation](h, "custom_validate_upsert", map[string]any{"token": token})
}

func (h *Handle) CustomValidateDelete(key string) (Mutation, error) {
	return call[Mutation](h, "custom_validate_delete", map[string]any{"key": key})
}

func (h *Handle) CustomCommit(id uint64) (Change, error) {
	return call[Change](h, "custom_commit", map[string]any{"mutationId": id})
}

func (h *Handle) CustomAbort(id uint64) (bool, error) {
	return call[bool](h, "custom_abort", map[string]any{"mutationId": id})
}

func (h *Handle) RefreshPlan(now int64, force bool) (RefreshPlan, error) {
	return call[RefreshPlan](h, "refresh_plan", map[string]any{"now": now, "force": force})
}

func (h *Handle) RefreshApply(id uint64, results []FetchResult, now int64) (RefreshReport, error) {
	return call[RefreshReport](h, "refresh_apply", struct {
		PlanID  uint64        `json:"planId"`
		Results []FetchResult `json:"results,omitempty"`
		Now     int64         `json:"now"`
	}{id, results, now})
}

func (h *Handle) RefreshCommit(id uint64, now int64) (Change, error) {
	return call[Change](h, "refresh_commit", map[string]any{"planId": id, "now": now})
}

func (h *Handle) RefreshAbort(id uint64, reason Status) (bool, error) {
	return call[bool](h, "refresh_abort", map[string]any{"planId": id, "reason": reasonName(reason)})
}

func (h *Handle) SetAutoRefresh(enabled bool, refreshSec, checkSec int64) (bool, error) {
	return call[bool](h, "set_auto_refresh", map[string]any{"enabled": enabled, "refreshSec": refreshSec, "checkSec": checkSec})
}

func (h *Handle) SetNetworkAllowed(allowed bool) (bool, error) {
	return call[bool](h, "set_network_allowed", map[string]any{"allowed": allowed})
}

func (h *Handle) NextDue(now int64) (*int64, error) {
	return call[*int64](h, "next_due", map[string]any{"now": now})
}

func (h *Handle) ChangesSince(revision uint64) (Page[Change], error) {
	return call[Page[Change]](h, "changes_since", map[string]any{"revision": revision})
}

func (h *Handle) RefreshState() (RefreshState, error) {
	return call[RefreshState](h, "refresh_state", struct{}{})
}

func reasonName(reason Status) string {
	if reason >= 0 && int(reason) < len(statusNames) {
		return statusNames[reason]
	}
	return "InvalidStatus"
}
