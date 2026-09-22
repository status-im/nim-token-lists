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

type operation func(C.uint64_t, *C.char, C.size_t, *C.TklBuf) C.int32_t

func (h *Handle) call(invoke operation, input any) ([]byte, error) {
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
	rc := invoke(h.h, p, n, &out)
	body := takeBuf(&out)
	if err = statusError(rc, body); err != nil {
		return nil, err
	}
	return body, nil
}
func call[T any](h *Handle, invoke operation, input any) (T, error) {
	var result T
	body, err := h.call(invoke, input)
	if err != nil {
		return result, err
	}
	err = json.Unmarshal(body, &result)
	return result, err
}

func (h *Handle) LoadStored(bootstrap Bootstrap) (Page[Change], error) {
	return call[Page[Change]](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_load_stored(handle, data, length, out)
	}, bootstrap)
}

func (h *Handle) GetAll(offset, limit int) (Page[Token], error) {
	return call[Page[Token]](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_get_all(handle, data, length, out)
	}, map[string]any{"offset": offset, "limit": limit})
}

func (h *Handle) GetByKey(key string) (Page[Token], error) {
	return call[Page[Token]](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_get_by_key(handle, data, length, out)
	}, map[string]any{"key": key})
}

func (h *Handle) GetByChainAddress(chainID uint64, address string) (Page[Token], error) {
	return call[Page[Token]](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_get_by_chain_address(handle, data, length, out)
	}, map[string]any{"chainId": chainID, "address": address})
}

func (h *Handle) GetNative(chainID uint64) (Page[Token], error) {
	return call[Page[Token]](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_get_native(handle, data, length, out)
	}, map[string]any{"chainId": chainID})
}

func (h *Handle) GetByKeys(keys []string) (Page[Token], error) {
	return call[Page[Token]](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_get_by_keys(handle, data, length, out)
	}, struct {
		Keys []string `json:"keys,omitempty"`
	}{keys})
}

func (h *Handle) GetByChains(chains []uint64, offset, limit int) (Page[Token], error) {
	return call[Page[Token]](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_get_by_chains(handle, data, length, out)
	}, struct {
		Chains []uint64 `json:"chains,omitempty"`
		Offset int      `json:"offset"`
		Limit  int      `json:"limit"`
	}{chains, offset, limit})
}

func (h *Handle) GetList(id string) (Page[TokenList], error) {
	return call[Page[TokenList]](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_get_list(handle, data, length, out)
	}, map[string]any{"id": id})
}

func (h *Handle) GetLists() (Page[TokenList], error) {
	return call[Page[TokenList]](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_get_lists(handle, data, length, out)
	}, struct{}{})
}

func (h *Handle) GetDiagnostics() (Page[Diagnostic], error) {
	return call[Page[Diagnostic]](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_get_diagnostics(handle, data, length, out)
	}, struct{}{})
}

func (h *Handle) SetChains(chains []uint64) (Change, error) {
	return call[Change](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_set_chains(handle, data, length, out)
	}, struct {
		Chains []uint64 `json:"chains,omitempty"`
	}{chains})
}

func (h *Handle) SetPolicy(policy Policy) (Change, error) {
	return call[Change](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_set_policy(handle, data, length, out)
	}, map[string]any{"policy": policy})
}

func (h *Handle) CustomValidateUpsert(token Token) (Mutation, error) {
	return call[Mutation](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_custom_validate_upsert(handle, data, length, out)
	}, map[string]any{"token": token})
}

func (h *Handle) CustomValidateDelete(key string) (Mutation, error) {
	return call[Mutation](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_custom_validate_delete(handle, data, length, out)
	}, map[string]any{"key": key})
}

func (h *Handle) CustomCommit(id uint64) (Change, error) {
	return call[Change](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_custom_commit(handle, data, length, out)
	}, map[string]any{"mutationId": id})
}

func (h *Handle) CustomAbort(id uint64) (bool, error) {
	return call[bool](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_custom_abort(handle, data, length, out)
	}, map[string]any{"mutationId": id})
}

func (h *Handle) RefreshPlan(now int64, force bool) (RefreshPlan, error) {
	return call[RefreshPlan](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_refresh_plan(handle, data, length, out)
	}, map[string]any{"now": now, "force": force})
}

func (h *Handle) RefreshApply(id uint64, results []FetchResult, now int64) (RefreshReport, error) {
	return call[RefreshReport](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_refresh_apply(handle, data, length, out)
	}, struct {
		PlanID  uint64        `json:"planId"`
		Results []FetchResult `json:"results,omitempty"`
		Now     int64         `json:"now"`
	}{id, results, now})
}

func (h *Handle) RefreshCommit(id uint64, now int64) (Change, error) {
	return call[Change](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_refresh_commit(handle, data, length, out)
	}, map[string]any{"planId": id, "now": now})
}

func (h *Handle) RefreshAbort(id uint64, reason Status) (bool, error) {
	return call[bool](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_refresh_abort(handle, data, length, out)
	}, map[string]any{"planId": id, "reason": reasonName(reason)})
}

func (h *Handle) SetAutoRefresh(enabled bool, refreshSec, checkSec int64) (bool, error) {
	return call[bool](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_set_auto_refresh(handle, data, length, out)
	}, map[string]any{"enabled": enabled, "refreshSec": refreshSec, "checkSec": checkSec})
}

func (h *Handle) SetNetworkAllowed(allowed bool) (bool, error) {
	return call[bool](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_set_network_allowed(handle, data, length, out)
	}, map[string]any{"allowed": allowed})
}

func (h *Handle) NextDue(now int64) (*int64, error) {
	return call[*int64](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_next_due(handle, data, length, out)
	}, map[string]any{"now": now})
}

func (h *Handle) ChangesSince(revision uint64) (Page[Change], error) {
	return call[Page[Change]](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_changes_since(handle, data, length, out)
	}, map[string]any{"revision": revision})
}

func (h *Handle) RefreshState() (RefreshState, error) {
	return call[RefreshState](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_refresh_state(handle, data, length, out)
	}, struct{}{})
}

func reasonName(reason Status) string {
	if reason >= 0 && int(reason) < len(statusNames) {
		return statusNames[reason]
	}
	return "InvalidStatus"
}
