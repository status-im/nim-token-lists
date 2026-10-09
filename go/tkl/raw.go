package tkl

/*
#include "tkl.h"
*/
import "C"
import (
	"encoding/json"
	"unsafe"
)

// rawOps names JSON operations for tests that check exact output bytes.
var rawOps = map[string]operation{
	"get_all": func(h C.uint64_t, d *C.char, n C.size_t, o *C.TklBuf) C.int32_t { return C.tkl_get_all(h, d, n, o) },
	"get_by_chains": func(h C.uint64_t, d *C.char, n C.size_t, o *C.TklBuf) C.int32_t {
		return C.tkl_get_by_chains(h, d, n, o)
	},
	"get_by_key":  func(h C.uint64_t, d *C.char, n C.size_t, o *C.TklBuf) C.int32_t { return C.tkl_get_by_key(h, d, n, o) },
	"get_by_keys": func(h C.uint64_t, d *C.char, n C.size_t, o *C.TklBuf) C.int32_t { return C.tkl_get_by_keys(h, d, n, o) },
	"get_by_chain_address": func(h C.uint64_t, d *C.char, n C.size_t, o *C.TklBuf) C.int32_t {
		return C.tkl_get_by_chain_address(h, d, n, o)
	},
	"get_native": func(h C.uint64_t, d *C.char, n C.size_t, o *C.TklBuf) C.int32_t { return C.tkl_get_native(h, d, n, o) },
	"get_list":   func(h C.uint64_t, d *C.char, n C.size_t, o *C.TklBuf) C.int32_t { return C.tkl_get_list(h, d, n, o) },
	"get_lists":  func(h C.uint64_t, d *C.char, n C.size_t, o *C.TklBuf) C.int32_t { return C.tkl_get_lists(h, d, n, o) },
	"get_diagnostics": func(h C.uint64_t, d *C.char, n C.size_t, o *C.TklBuf) C.int32_t {
		return C.tkl_get_diagnostics(h, d, n, o)
	},
	"changes_since": func(h C.uint64_t, d *C.char, n C.size_t, o *C.TklBuf) C.int32_t {
		return C.tkl_changes_since(h, d, n, o)
	},
	"set_chains": func(h C.uint64_t, d *C.char, n C.size_t, o *C.TklBuf) C.int32_t { return C.tkl_set_chains(h, d, n, o) },
	"set_policy": func(h C.uint64_t, d *C.char, n C.size_t, o *C.TklBuf) C.int32_t { return C.tkl_set_policy(h, d, n, o) },
	"custom_commit": func(h C.uint64_t, d *C.char, n C.size_t, o *C.TklBuf) C.int32_t {
		return C.tkl_custom_commit(h, d, n, o)
	},
	"refresh_commit": func(h C.uint64_t, d *C.char, n C.size_t, o *C.TklBuf) C.int32_t {
		return C.tkl_refresh_commit(h, d, n, o)
	},
}

// raw runs a named operation and returns its status and exact output bytes.
func (h *Handle) raw(name string, input any) (int32, []byte, error) {
	data, err := json.Marshal(input)
	if err != nil {
		return 0, nil, err
	}
	var out C.TklBuf
	rc := rawOps[name](h.h, (*C.char)(unsafe.Pointer(unsafe.SliceData(data))), C.size_t(len(data)), &out)
	return int32(rc), takeBuf(&out), nil
}
