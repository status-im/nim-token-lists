// Package tkl is the cgo binding for libtkl (spike).
// Callers provide include/library paths via CGO_CFLAGS / CGO_LDFLAGS.
package tkl

/*
#cgo LDFLAGS: -ltkl
#cgo linux LDFLAGS: -lm -lpthread
#include <stdint.h>
#include <stdlib.h>
#include "tkl.h"
*/
import "C"

import (
	"strconv"
	"unsafe"
)

// Status is a libtkl status code. Non-zero values are errors; compare with errors.Is.
type Status int32

const (
	Ok Status = iota
	NotFound
	Unchanged
	Aborted
	SupersededPlan
	Busy
	PartialSuccess
	InvalidContent
	UnsupportedSchema
	UnsupportedChain
	ValidationFailed
	NetworkFailure
	StorageFailure
	InvalidArgument
	InvalidHandle
	Closed
	AbiMismatch
	Internal
)

var statusNames = [...]string{
	"ok", "not found", "unchanged", "aborted", "superseded plan", "busy",
	"partial success", "invalid content", "unsupported schema", "unsupported chain",
	"validation failed", "network failure", "storage failure", "invalid argument",
	"invalid handle", "closed", "abi mismatch", "internal",
}

func (s Status) Error() string {
	if int(s) >= 0 && int(s) < len(statusNames) {
		return "tkl: " + statusNames[s]
	}
	return "tkl: status " + strconv.Itoa(int(s))
}

func check(rc C.int32_t) error {
	if rc == 0 {
		return nil
	}
	return Status(rc)
}

// Handle is one library instance. Safe for concurrent use from any goroutine.
type Handle struct{ h C.uint64_t }

func ABIVersion() uint32 { return uint32(C.tkl_abi_version()) }

func Create() (*Handle, error) {
	var h C.uint64_t
	if err := check(C.tkl_create(C.uint32_t(C.TKL_ABI_VERSION), &h)); err != nil {
		return nil, err
	}
	return &Handle{h: h}, nil
}

func (h *Handle) Destroy() error { return check(C.tkl_destroy(h.h)) }

func (h *Handle) Stage(tokensJSON []byte) (uint64, error) {
	var p *C.char
	if len(tokensJSON) > 0 {
		p = (*C.char)(unsafe.Pointer(unsafe.SliceData(tokensJSON)))
	}
	var id C.uint64_t
	if err := check(C.tkl_stage_tokens(h.h, p, C.size_t(len(tokensJSON)), &id)); err != nil {
		return 0, err
	}
	return uint64(id), nil
}

func (h *Handle) Commit(stagedID uint64) (uint64, error) {
	var rev C.uint64_t
	if err := check(C.tkl_commit(h.h, C.uint64_t(stagedID), &rev)); err != nil {
		return 0, err
	}
	return uint64(rev), nil
}

func (h *Handle) Abort(stagedID uint64) error {
	return check(C.tkl_abort(h.h, C.uint64_t(stagedID)))
}

func takeBuf(buf *C.TklBuf) []byte {
	defer C.tkl_buf_free(buf)
	if buf.data == nil || buf.len == 0 {
		return nil
	}
	return C.GoBytes(unsafe.Pointer(buf.data), C.int(buf.len))
}

func (h *Handle) GetByKey(key string) ([]byte, error) {
	if key == "" {
		return nil, InvalidArgument
	}
	var buf C.TklBuf
	p := (*C.char)(unsafe.Pointer(unsafe.StringData(key)))
	if err := check(C.tkl_get_by_key(h.h, p, C.size_t(len(key)), &buf)); err != nil {
		return nil, err
	}
	return takeBuf(&buf), nil
}

func (h *Handle) GetAll() ([]byte, error) {
	var buf C.TklBuf
	if err := check(C.tkl_get_all(h.h, &buf)); err != nil {
		return nil, err
	}
	return takeBuf(&buf), nil
}

func (h *Handle) Revision() uint64 { return uint64(C.tkl_revision(h.h)) }
