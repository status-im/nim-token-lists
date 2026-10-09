package tkl

import (
	"os"
	"testing"
)

// Fixture paths are relative to this package's directory. A test binary run
// elsewhere (a device or simulator) names that directory in TKL_TEST_DIR.
func TestMain(m *testing.M) {
	if dir := os.Getenv("TKL_TEST_DIR"); dir != "" {
		if err := os.Chdir(dir); err != nil {
			panic(err)
		}
	}
	os.Exit(m.Run())
}
