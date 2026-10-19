package executor

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"package-runner/internal/integrity"
	"package-runner/internal/logging"
	"package-runner/internal/models"
)

// lockPackage returns one package entry whose install is a PowerShell script
// that writes marker, followed by the given validation list.
func lockPackage(t *testing.T, dir, name, marker, validation string) string {
	t.Helper()
	script := filepath.Join(dir, name+".ps1")
	body := fmt.Sprintf("Set-Content -LiteralPath '%s' -Value 'installed' -Encoding ASCII\nexit 0\n", marker)
	if err := os.WriteFile(script, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return fmt.Sprintf(`
    - name: %s
      version: 1.0.0
      install:
        handler: powershell
        timeout: 2m0s
        successExitCodes: [0]
      validation:
%s
      artifact:
        filename: %q
        sha256: %s
        sizeBytes: %d
`, name, validation, script, sha256Hex(body), len(body))
}

func TestRunFailsWhenAValidationFailsAndRecordsTheEvidence(t *testing.T) {
	dir := t.TempDir()
	goodMarker := filepath.Join(dir, "good.txt")
	badMarker := filepath.Join(dir, "bad.txt")

	lock := "apiVersion: image.example/v1alpha1\nkind: ImageRecipeLock\nmetadata:\n    name: test\n    version: 0.0.1\npackages:" +
		lockPackage(t, dir, "good", goodMarker, fmt.Sprintf("        - handler: file\n          parameters:\n            path: %q", goodMarker)) +
		// Installs, but validates a file the install does not create, and
		// names a validator type that does not exist.
		lockPackage(t, dir, "bad", badMarker, fmt.Sprintf("        - handler: file\n          parameters:\n            path: %q\n        - handler: no-such-type\n          parameters:\n            x: 1", filepath.Join(dir, "never-written.txt")))
	lockPath := filepath.Join(dir, "lock.yaml")
	if err := os.WriteFile(lockPath, []byte(lock), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := integrity.WriteSidecar(lockPath); err != nil {
		t.Fatal(err)
	}

	var logs bytes.Buffer
	evidenceDir := filepath.Join(dir, "evidence")
	result, err := NewExecutor(&ExecutorConfig{
		LockPath:       lockPath,
		EvidenceDir:    evidenceDir,
		ExecutionID:    "exec-1",
		Logger:         logging.NewJSONLogger(&logs, logging.LevelInfo),
		ElevationCheck: func() bool { return true },
	}).Run()
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	if result.OverallSuccess {
		t.Error("a failed validation must fail the run")
	}
	if len(result.SuccessfulPackages) != 1 || result.SuccessfulPackages[0] != "good" {
		t.Errorf("successful packages = %v, want [good]", result.SuccessfulPackages)
	}
	if len(result.FailedPackages) != 1 || result.FailedPackages[0] != "bad" {
		t.Errorf("failed packages = %v, want [bad]", result.FailedPackages)
	}

	written := readResult(t, filepath.Join(evidenceDir, InstallResultFile))

	good := written["good"]
	if good.Status != models.PackageStatusSuccess || good.Validation == nil || len(good.Validation.Results) != 1 {
		t.Fatalf("good: %+v", good)
	}
	if v := good.Validation.Results[0]; v.Package != "good" || v.PackageVersion != "1.0.0" || v.Result != models.ValidationResultPassed || v.Observed["sha256"] == nil {
		t.Errorf("good evidence: %+v", v)
	}

	bad := written["bad"]
	if bad.Status != models.PackageStatusValidationFailed || bad.Validation == nil || len(bad.Validation.Results) != 2 || bad.Validation.Passed {
		t.Fatalf("bad: %+v", bad)
	}
	for _, v := range bad.Validation.Results {
		if v.Package != "bad" || v.Result != models.ValidationResultFailed {
			t.Errorf("bad evidence: %+v", v)
		}
	}
	if bad.Validation.Results[1].Validator != "no-such-type" || bad.Validation.Results[1].Error == "" {
		t.Errorf("a validator that cannot be created must still leave a record: %+v", bad.Validation.Results[1])
	}

	// Every evidence log entry names the package and the execution.
	evidenceEntries := 0
	for _, line := range strings.Split(strings.TrimSpace(logs.String()), "\n") {
		var entry struct {
			ExecutionID string                 `json:"executionId"`
			Fields      map[string]interface{} `json:"fields"`
		}
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatalf("log line is not JSON: %s", line)
		}
		if entry.Fields["event"] != "validation.evidence" {
			continue
		}
		evidenceEntries++
		if entry.ExecutionID != "exec-1" || entry.Fields["package"] == nil || entry.Fields["package_version"] != "1.0.0" {
			t.Errorf("evidence entry does not identify its package and run: %s", line)
		}
	}
	if evidenceEntries != 3 {
		t.Errorf("want 3 evidence log entries, got %d", evidenceEntries)
	}
}
