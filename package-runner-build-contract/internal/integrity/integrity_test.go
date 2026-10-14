package integrity

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSidecarRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lock.yaml")
	if err := os.WriteFile(path, []byte("kind: ImageRecipeLock\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := WriteSidecar(path); err != nil {
		t.Fatal(err)
	}

	line, err := os.ReadFile(path + SidecarSuffix)
	if err != nil {
		t.Fatal(err)
	}
	// The format sha256sum -c reads: hash, two spaces, base name.
	want, _, _ := FileSHA256(path)
	if string(line) != want+"  lock.yaml\n" {
		t.Fatalf("sidecar = %q", line)
	}

	got, err := VerifySidecar(path)
	if err != nil || got != want {
		t.Fatalf("VerifySidecar = %q, %v", got, err)
	}
}

func TestVerifySidecarAcceptsWhatOtherToolsWrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lock.yaml")
	if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	sum, _, _ := FileSHA256(path)
	for name, content := range map[string]string{
		"upper case":             strings.ToUpper(sum) + "  lock.yaml\n",
		"binary marker":          sum + " *lock.yaml\n",
		"windows line ending":    sum + "  lock.yaml\r\n",
		"byte order mark":        string(rune(0xFEFF)) + sum + "  lock.yaml\n",
		"another file name":      sum + "  renamed-on-the-way.yaml\n",
		"hash alone, no newline": sum,
	} {
		if err := os.WriteFile(path+SidecarSuffix, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := VerifySidecar(path); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestVerifySidecarFailures(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lock.yaml")
	if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := VerifySidecar(path); !errors.Is(err, ErrNoSidecar) {
		t.Errorf("a missing sidecar must be reported as ErrNoSidecar, got %v", err)
	}
	for name, content := range map[string]string{
		"empty":            "",
		"not a hash":       "hello  lock.yaml\n",
		"short hash":       strings.Repeat("a", 63) + "  lock.yaml\n",
		"a different hash": strings.Repeat("0", 64) + "  lock.yaml\n",
	} {
		if err := os.WriteFile(path+SidecarSuffix, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := VerifySidecar(path); err == nil || errors.Is(err, ErrNoSidecar) {
			t.Errorf("%s: must be a failure, not a missing sidecar: %v", name, err)
		}
	}
}
