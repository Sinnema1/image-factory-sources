//go:build windows

package validators

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows/registry"

	"package-runner/internal/logging"
	"package-runner/internal/models"
)

// run creates and runs a validator with a JSON logger, and returns its one
// evidence record and the log entries it wrote.
func run(t *testing.T, handler string, params map[string]interface{}) (models.ValidationEvidence, error, []map[string]interface{}) {
	t.Helper()
	var logs bytes.Buffer
	validator, err := NewValidator(handler, params, logging.NewJSONLogger(&logs, logging.LevelInfo))
	if err != nil {
		t.Fatalf("NewValidator: %v", err)
	}
	result, validateErr := validator.Validate()
	if result == nil {
		t.Fatalf("Validate returned no result (err: %v)", validateErr)
	}
	if len(result.Validations) != 1 {
		t.Fatalf("want 1 evidence record, got %d", len(result.Validations))
	}
	if passed := result.Status == models.PackageStatusSuccess; passed != (validateErr == nil) {
		t.Fatalf("status %q does not agree with error %v", result.Status, validateErr)
	}

	var entries []map[string]interface{}
	decoder := json.NewDecoder(&logs)
	for decoder.More() {
		var entry map[string]interface{}
		if err := decoder.Decode(&entry); err != nil {
			t.Fatalf("log entry is not JSON: %v", err)
		}
		entries = append(entries, entry)
	}
	return result.Validations[0], validateErr, entries
}

func checkNamed(t *testing.T, evidence models.ValidationEvidence, name string) models.ValidationCheck {
	t.Helper()
	for _, check := range evidence.Checks {
		if check.Name == name {
			return check
		}
	}
	t.Fatalf("no %q check in %+v", name, evidence.Checks)
	return models.ValidationCheck{}
}

func writeFile(t *testing.T, content string) (string, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "installed.txt")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(content))
	return path, hex.EncodeToString(sum[:])
}

func TestFileValidatorPassRecordsChecksAndObservedFacts(t *testing.T) {
	path, hash := writeFile(t, "fixture")
	evidence, err, entries := run(t, "file", map[string]interface{}{
		"path": path, "sha256": hash, "sizeBytes": 7,
	})
	if err != nil {
		t.Fatalf("want pass, got %v", err)
	}
	if evidence.Result != models.ValidationResultPassed || evidence.ChecksPassed != 3 || evidence.ChecksTotal != 3 {
		t.Fatalf("unexpected evidence: %+v", evidence)
	}
	if got := evidence.Observed["sha256"]; got != hash {
		t.Fatalf("observed sha256 = %v, want the full hash %s", got, hash)
	}
	if evidence.Observed["size_bytes"] != int64(7) || evidence.Observed["modified_utc"] == nil {
		t.Fatalf("observed facts missing: %+v", evidence.Observed)
	}
	if evidence.Target != path || evidence.Host == "" {
		t.Fatalf("target or host missing: %+v", evidence)
	}

	if len(entries) != 1 {
		t.Fatalf("want 1 log entry, got %d", len(entries))
	}
	fields := entries[0]["fields"].(map[string]interface{})
	if entries[0]["level"] != "INFO" || fields["event"] != "validation.evidence" || fields["result"] != "PASSED" {
		t.Fatalf("unexpected log entry: %v", entries[0])
	}
	if fields["observed.sha256"] != hash || fields["checks_total"] != float64(3) {
		t.Fatalf("log fields do not carry the evidence: %v", fields)
	}
	if checks, ok := fields["checks"].([]interface{}); !ok || len(checks) != 3 {
		t.Fatalf("checks are not a list of 3 in the log: %v", fields["checks"])
	}
}

func TestFileValidatorObservesHashWithoutBeingAsked(t *testing.T) {
	path, hash := writeFile(t, "fixture")
	evidence, err, _ := run(t, "file", map[string]interface{}{"path": path})
	if err != nil {
		t.Fatalf("want pass, got %v", err)
	}
	if evidence.ChecksTotal != 1 || evidence.Observed["sha256"] != hash {
		t.Fatalf("unexpected evidence: %+v", evidence)
	}
}

func TestFileValidatorMissingFileListsEveryRequestedCheck(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "absent.exe")
	evidence, err, entries := run(t, "file", map[string]interface{}{
		"path": missing, "sha256": "aa", "sizeBytes": 1, "version": "1.0.0.0",
	})
	if err == nil {
		t.Fatal("want failure for a missing file")
	}
	if evidence.Result != models.ValidationResultFailed || evidence.ChecksTotal != 4 || evidence.ChecksPassed != 0 {
		t.Fatalf("unexpected evidence: %+v", evidence)
	}
	if exists := checkNamed(t, evidence, "exists"); exists.Expected != true || exists.Actual != false {
		t.Fatalf("exists check: %+v", exists)
	}
	if len(evidence.Observed) != 0 {
		t.Fatalf("a missing file has nothing to observe: %+v", evidence.Observed)
	}
	if entries[0]["level"] != "ERROR" {
		t.Fatalf("a failure must log at ERROR: %v", entries[0])
	}
}

func TestFileValidatorKeepsCheckingAfterAFailure(t *testing.T) {
	path, hash := writeFile(t, "fixture")
	evidence, err, _ := run(t, "file", map[string]interface{}{
		"path": path, "sizeBytes": 999, "sha256": hash,
	})
	if err == nil {
		t.Fatal("want failure for a size mismatch")
	}
	if evidence.ChecksTotal != 3 || evidence.ChecksPassed != 2 {
		t.Fatalf("want 2 of 3 checks passed, got %+v", evidence)
	}
	if size := checkNamed(t, evidence, "size_bytes"); size.Passed || size.Actual != int64(7) {
		t.Fatalf("size check: %+v", size)
	}
	if !checkNamed(t, evidence, "sha256").Passed {
		t.Fatal("the hash check must still run and pass")
	}
}

func TestFileValidatorDirectoryIsNotAFile(t *testing.T) {
	evidence, err, _ := run(t, "file", map[string]interface{}{"path": t.TempDir()})
	if err == nil || checkNamed(t, evidence, "exists").Passed {
		t.Fatalf("a directory must not pass: %+v", evidence)
	}
}

func TestFileValidatorVersionOfAWindowsBinary(t *testing.T) {
	path := filepath.Join(os.Getenv("SystemRoot"), "System32", "cmd.exe")
	if _, err := os.Stat(path); err != nil {
		t.Skip("no cmd.exe to read a version resource from")
	}
	observed, err, _ := run(t, "file", map[string]interface{}{"path": path})
	if err != nil {
		t.Fatalf("want pass, got %v", err)
	}
	version, _ := observed.Observed["file_version"].(string)
	if version == "" || observed.Observed["company_name"] == nil || observed.Observed["product_name"] == nil {
		t.Fatalf("version resource not observed: %+v", observed.Observed)
	}

	// The version must be the one in the file. Windows reports its own files
	// as 6.2 to a process with no compatibility manifest; cmd.exe carries the
	// operating system's real major version.
	key, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\Windows NT\CurrentVersion`, registry.QUERY_VALUE)
	if err != nil {
		t.Fatal(err)
	}
	defer key.Close()
	major, _, err := key.GetIntegerValue("CurrentMajorVersionNumber")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(version, fmt.Sprintf("%d.", major)) {
		t.Fatalf("file version %s does not start with the Windows major version %d", version, major)
	}

	matched, err, _ := run(t, "file", map[string]interface{}{"path": path, "version": version})
	if err != nil || !checkNamed(t, matched, "version").Passed {
		t.Fatalf("the observed version must satisfy a version check: %v %+v", err, matched)
	}
	mismatched, err, _ := run(t, "file", map[string]interface{}{"path": path, "version": "0.0.0.1"})
	if err == nil || checkNamed(t, mismatched, "version").Actual != version {
		t.Fatalf("a wrong version must fail and record the real one: %v %+v", err, mismatched)
	}
}

func TestFileValidatorVersionAskedOfAFileWithoutOne(t *testing.T) {
	path, _ := writeFile(t, "fixture")
	evidence, err, _ := run(t, "file", map[string]interface{}{"path": path, "version": "1.0.0.0"})
	if err == nil || checkNamed(t, evidence, "version").Passed {
		t.Fatalf("a file with no version resource cannot pass a version check: %+v", evidence)
	}
}

func TestServiceValidatorReadsARealService(t *testing.T) {
	// The event log service runs on every Windows installation.
	evidence, err, _ := run(t, "service", map[string]interface{}{
		"serviceName": "EventLog", "state": "Running", "startType": "automatic",
	})
	if err != nil {
		t.Fatalf("want pass, got %v (%+v)", err, evidence)
	}
	if evidence.ChecksTotal != 3 || evidence.Observed["state"] != "running" {
		t.Fatalf("unexpected evidence: %+v", evidence)
	}

	wrong, err, _ := run(t, "service", map[string]interface{}{"serviceName": "EventLog", "state": "stopped"})
	if err == nil || checkNamed(t, wrong, "state").Actual != "running" {
		t.Fatalf("a wrong state must fail and record the real one: %v %+v", err, wrong)
	}
}

func TestServiceValidatorMissingServiceFails(t *testing.T) {
	evidence, err, _ := run(t, "service", map[string]interface{}{
		"serviceName": "package-runner-no-such-service", "state": "running",
	})
	if err == nil {
		t.Fatal("a service that does not exist must not pass")
	}
	if checkNamed(t, evidence, "exists").Passed || checkNamed(t, evidence, "state").Passed {
		t.Fatalf("unexpected evidence: %+v", evidence)
	}
}

func TestRegistryValidator(t *testing.T) {
	key := `SOFTWARE\Microsoft\Windows NT\CurrentVersion`
	observed, err, _ := run(t, "registry", map[string]interface{}{"hive": "HKLM", "key": key, "value": "CurrentBuild"})
	if err != nil {
		t.Fatalf("existence check should pass: %v (%+v)", err, observed)
	}
	build, _ := observed.Observed["data"].(string)
	if build == "" || observed.Observed["value_type"] != "REG_SZ" || observed.ChecksTotal != 2 {
		t.Fatalf("unexpected evidence: %+v", observed)
	}

	if _, err, _ := run(t, "registry", map[string]interface{}{"hive": "HKLM", "key": key, "value": "CurrentBuild", "data": build}); err != nil {
		t.Fatalf("matching data should pass: %v", err)
	}
	wrong, err, _ := run(t, "registry", map[string]interface{}{"hive": "HKLM", "key": key, "value": "CurrentBuild", "data": "0"})
	if err == nil || checkNamed(t, wrong, "data").Actual != build {
		t.Fatalf("wrong data must fail and record the real value: %v %+v", err, wrong)
	}
	missing, err, _ := run(t, "registry", map[string]interface{}{"hive": "HKLM", "key": key + `\NoSuchKey`, "value": "x", "data": "1"})
	if err == nil || missing.ChecksTotal != 3 || missing.ChecksPassed != 0 {
		t.Fatalf("a missing key must fail every check: %v %+v", err, missing)
	}
}

func TestRegistryDataEqualComparesIntegersByValue(t *testing.T) {
	for _, expected := range []interface{}{1, int64(1), float64(1), uint64(1)} {
		if !registryDataEqual(expected, uint64(1)) {
			t.Fatalf("%T(1) should equal a DWORD of 1", expected)
		}
	}
	if registryDataEqual("1", uint64(1)) || registryDataEqual(2, uint64(1)) {
		t.Fatal("a string or a different number must not equal a DWORD of 1")
	}
}

func TestCommandValidator(t *testing.T) {
	passed, err, _ := run(t, "command", map[string]interface{}{
		"command": "cmd.exe", "arguments": []interface{}{"/c", "exit 0"},
	})
	if err != nil || passed.ChecksPassed != 2 {
		t.Fatalf("exit 0 should pass: %v %+v", err, passed)
	}
	failed, err, _ := run(t, "command", map[string]interface{}{
		"command": "cmd.exe", "arguments": []interface{}{"/c", "exit 3"},
	})
	if err == nil || checkNamed(t, failed, "exit_code").Actual != 3 {
		t.Fatalf("exit 3 must fail and be recorded: %v %+v", err, failed)
	}
}

func TestFailedEvidenceForAValidatorThatCouldNotRun(t *testing.T) {
	_, err := NewValidator("no-such-type", map[string]interface{}{}, nil)
	if err == nil {
		t.Fatal("an unknown validator type must be an error")
	}
	evidence := FailedEvidence("no-such-type", err)
	if evidence.Result != models.ValidationResultFailed || evidence.Error == "" || evidence.Checks == nil {
		t.Fatalf("unexpected evidence: %+v", evidence)
	}
}
