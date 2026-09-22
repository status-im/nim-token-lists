NIM ?= nim
NIM_TEST_FLAGS := --mm:orc -d:useMalloc --threads:on --skipParentCfg:on --nimcache:build/nimcache-tests

.PHONY: lib test-core test-nim test-c test-go bench bench-parse bench-catalogue fuzz-core isolate audit clean
lib:
	NIM="$(NIM)" scripts/build_lib.sh
test-core:
	NIM="$(NIM)" bash scripts/test_core.sh
bench-parse:
	NIM="$(NIM)" bash scripts/bench_parse.sh
bench-catalogue:
	NIM="$(NIM)" bash scripts/bench_catalogue.sh
fuzz-core:
	NIM="$(NIM)" bash scripts/fuzz_core.sh parsers
	NIM="$(NIM)" bash scripts/fuzz_core.sh planner
test-nim:
	"$(NIM)" c -r $(NIM_TEST_FLAGS) -o:build/test_snapshot tests/core/test_snapshot.nim
test-c: lib
	cc -std=c11 -Wall -Wextra -o build/smoke tests/abi/smoke.c -Iabi build/libtkl.a -lpthread -lm
	build/smoke
	cc -std=c11 -Wall -Wextra -o build/lengths tests/abi/lengths.c -Iabi build/libtkl.a -lpthread -lm
	build/lengths
test-go: lib
	cd go/tkl && CGO_CFLAGS="-I$(CURDIR)/abi" CGO_LDFLAGS="-L$(CURDIR)/build" go test -race -count=1 ./...
bench: lib
	cd go/tkl && CGO_CFLAGS="-I$(CURDIR)/abi" CGO_LDFLAGS="-L$(CURDIR)/build" go test -run '^$$' -bench . -benchmem ./...
isolate: lib
	scripts/isolate_lib.sh
audit: isolate
	bash tests/symbols/test_audit.sh
clean:
	rm -rf build
