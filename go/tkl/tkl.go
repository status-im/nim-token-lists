// Package tkl calls the Nim token catalogue exclusively through its versioned C ABI.
// Callers provide include/library paths via CGO_CFLAGS and CGO_LDFLAGS.
package tkl

/*
#cgo LDFLAGS: -ltkl
#cgo linux LDFLAGS: -lm
#cgo linux,!android LDFLAGS: -lpthread
#include "tkl.h"
*/
import "C"
import (
	"encoding/binary"
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
// List bodies are borrowed for one call and may be reused once it returns.
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

func bytesArg(data []byte) (*C.char, C.size_t) {
	return (*C.char)(unsafe.Pointer(unsafe.SliceData(data))), C.size_t(len(data))
}
func stringArg(value string) (*C.char, C.size_t) {
	return (*C.char)(unsafe.Pointer(unsafe.StringData(value))), C.size_t(len(value))
}
func (h *Handle) bodyCall(invoke func(*C.TklBuf) C.int32_t) error {
	if h == nil {
		return InvalidHandle
	}
	var out C.TklBuf
	rc := invoke(&out)
	return statusError(rc, takeBuf(&out))
}

// LoadBegin opens a load of the host's persisted state and returns its id.
func (h *Handle) LoadBegin(bootstrap Bootstrap) (uint64, error) {
	if h == nil {
		return 0, InvalidHandle
	}
	data, err := json.Marshal(bootstrap)
	if err != nil {
		return 0, err
	}
	var txn C.uint64_t
	var out C.TklBuf
	p, n := bytesArg(data)
	rc := C.tkl_load_begin(h.h, p, n, &txn, &out)
	if err = statusError(rc, takeBuf(&out)); err != nil {
		return 0, err
	}
	return uint64(txn), nil
}

// LoadList parses one body into the open load; body is not retained.
func (h *Handle) LoadList(txn uint64, id string, origin BodyOrigin, body []byte) error {
	return h.bodyCall(func(out *C.TklBuf) C.int32_t {
		idp, idn := stringArg(id)
		p, n := bytesArg(body)
		return C.tkl_load_list(h.h, C.uint64_t(txn), idp, idn, C.uint32_t(origin), p, n, out)
	})
}

// LoadFinish publishes revision one from the bodies loaded so far.
func (h *Handle) LoadFinish(txn uint64) (Page[Change], error) {
	var result Page[Change]
	if h == nil {
		return result, InvalidHandle
	}
	var out C.TklBuf
	rc := C.tkl_load_finish(h.h, C.uint64_t(txn), &out)
	body := takeBuf(&out)
	if err := statusError(rc, body); err != nil {
		return result, err
	}
	err := json.Unmarshal(body, &result)
	return result, err
}

func (h *Handle) LoadAbort(txn uint64) error {
	return h.bodyCall(func(out *C.TklBuf) C.int32_t {
		return C.tkl_load_abort(h.h, C.uint64_t(txn), out)
	})
}

// LoadStored loads in one call: stored bodies first, so bundled lists replaced
// by usable stored copies are never parsed. A failed load is aborted.
func (h *Handle) LoadStored(bootstrap Bootstrap, bodies []ListBody) (Page[Change], error) {
	txn, err := h.LoadBegin(bootstrap)
	if err != nil {
		return Page[Change]{}, err
	}
	for _, origin := range []BodyOrigin{Stored, Bundled} {
		for _, body := range bodies {
			if body.Origin != origin {
				continue
			}
			if err = h.LoadList(txn, body.ID, body.Origin, body.Data); err != nil {
				_ = h.LoadAbort(txn)
				return Page[Change]{}, err
			}
		}
	}
	return h.LoadFinish(txn)
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

// GetByChainAddresses looks up many tokens in one call; unknown pairs are
// omitted and the rest keep request order.
func (h *Handle) GetByChainAddresses(pairs []Identity) (Page[Token], error) {
	chainIDs := make([]uint64, len(pairs))
	addresses := make([]string, len(pairs))
	for i, pair := range pairs {
		chainIDs[i], addresses[i] = pair.ChainID, pair.Address
	}
	return call[Page[Token]](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_get_by_chain_addresses(handle, data, length, out)
	}, struct {
		ChainIDs  []uint64 `json:"chainIds,omitempty"`
		Addresses []string `json:"addresses,omitempty"`
	}{chainIDs, addresses})
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

// ChainToken is a catalogue token narrowed to what balance fetching reads.
type ChainToken struct {
	ChainID  uint64
	Address  [20]byte
	Decimals uint8
}

// GetByChainsPacked answers GetByChains(chains, 0, 0) as ChainTokens, in the
// same order, without JSON. It fills dst[:0] when it has room, otherwise one
// new slice, and also returns the revision answered.
func (h *Handle) GetByChainsPacked(chains []uint64, dst []ChainToken) ([]ChainToken, uint64, error) {
	if h == nil {
		return dst[:0], 0, InvalidHandle
	}
	var out C.TklBuf
	rc := C.tkl_get_by_chains_packed(h.h, (*C.uint64_t)(unsafe.SliceData(chains)), C.size_t(len(chains)), &out)
	return decodePacked(rc, &out, dst)
}

// GetByCrossChainIDsPacked answers the tokens whose cross-chain id is one of
// the non-empty ids, in GetAll order, as ChainTokens without JSON output. It
// fills dst like GetByChainsPacked.
func (h *Handle) GetByCrossChainIDsPacked(ids []string, dst []ChainToken) ([]ChainToken, uint64, error) {
	if h == nil {
		return dst[:0], 0, InvalidHandle
	}
	data, err := json.Marshal(struct {
		CrossChainIDs []string `json:"crossChainIds,omitempty"`
	}{ids})
	if err != nil {
		return dst[:0], 0, err
	}
	var out C.TklBuf
	p, n := bytesArg(data)
	rc := C.tkl_get_by_cross_chain_ids_packed(h.h, p, n, &out)
	return decodePacked(rc, &out, dst)
}

// decodePacked releases a packed answer after decoding it into dst.
func decodePacked(rc C.int32_t, out *C.TklBuf, dst []ChainToken) ([]ChainToken, uint64, error) {
	if rc != 0 {
		return dst[:0], 0, statusError(rc, takeBuf(out))
	}
	defer C.tkl_buf_free(out)
	const header, record = C.TKL_PACKED_HEADER_BYTES, C.TKL_PACKED_RECORD_BYTES
	data := unsafe.Slice((*byte)(unsafe.Pointer(out.data)), int(out.len))
	if len(data) < header || binary.LittleEndian.Uint32(data) != C.TKL_PACKED_MAGIC {
		return dst[:0], 0, Internal
	}
	count := int(binary.LittleEndian.Uint32(data[4:]))
	if len(data) != header+count*record {
		return dst[:0], 0, Internal
	}
	if cap(dst) < count {
		dst = make([]ChainToken, count)
	}
	dst = dst[:count]
	for i := range dst {
		r := data[header+i*record : header+(i+1)*record]
		dst[i].ChainID = binary.LittleEndian.Uint64(r)
		copy(dst[i].Address[:], r[8:28])
		dst[i].Decimals = r[28]
	}
	return dst, binary.LittleEndian.Uint64(data[8:]), nil
}

// GetBySymbolOnChain answers the chain's tokens whose symbol or name equals
// symbol ignoring ASCII case, in GetByChains order: legacy payment requests
// name a token only by symbol.
func (h *Handle) GetBySymbolOnChain(chainID uint64, symbol string) (Page[Token], error) {
	return call[Page[Token]](h, func(handle C.uint64_t, data *C.char, length C.size_t, out *C.TklBuf) C.int32_t {
		return C.tkl_get_by_symbol_on_chain(handle, data, length, out)
	}, struct {
		ChainID uint64 `json:"chainId"`
		Symbol  string `json:"symbol"`
	}{chainID, symbol})
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

// RefreshPutBody validates and parses one fetched body of the current round.
func (h *Handle) RefreshPutBody(planID uint64, id string, body []byte) error {
	return h.bodyCall(func(out *C.TklBuf) C.int32_t {
		idp, idn := stringArg(id)
		p, n := bytesArg(body)
		return C.tkl_refresh_put_body(h.h, C.uint64_t(planID), idp, idn, p, n, out)
	})
}

// RefreshApply puts the non-nil body of every successful response, then
// applies the batch; a nil Body keeps one already passed to RefreshPutBody.
// Report writes are metadata: persist the fetched bodies by write ID.
func (h *Handle) RefreshApply(id uint64, results []FetchResult, now int64) (RefreshReport, error) {
	for _, result := range results {
		if result.Status == 200 && result.Failure == nil && result.Body != nil {
			if err := h.RefreshPutBody(id, result.ID, result.Body); err != nil {
				return RefreshReport{}, err
			}
		}
	}
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
