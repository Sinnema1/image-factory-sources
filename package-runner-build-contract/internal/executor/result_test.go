package executor

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"package-runner/internal/integrity"
	"package-runner/internal/models"
)

var utcToTheSecond = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$`)

func TestExitCodeAndOutcome(t *testing.T) {
	cases := []struct {
		name    string
		result  ExecutionResult
		code    int
		outcome string
	}{
		{"all installed", ExecutionResult{OverallSuccess: true}, 0, OutcomeSuccess},
		{"restart needed", ExecutionResult{OverallSuccess: true, RestartRequired: true}, 3010, OutcomeSuccess},
		{"a package failed", ExecutionResult{}, 10, OutcomeFailed},
		{"integrity", ExecutionResult{IntegrityFailure: true}, 11, OutcomeFailed},
		{"not elevated", ExecutionResult{NotElevated: true}, 12, OutcomeFailed},
		// The earlier check is the one reported.
		{"not elevated and integrity", ExecutionResult{NotElevated: true, IntegrityFailure: true}, 12, OutcomeFailed},
	}
	for _, c := range cases {
		if got := c.result.ExitCode(); got != c.code {
			t.Errorf("%s: exit code %d, want %d", c.name, got, c.code)
		}
		if got := c.result.Outcome(); got != c.outcome {
			t.Errorf("%s: outcome %q, want %q", c.name, got, c.outcome)
		}
	}
}

func TestInstallResultFile(t *testing.T) {
	run := stagePackages(t,
		testPackage{name: "first", script: "Write-Output 'TOKEN=not-for-the-result-file'\n[Console]::Error.WriteLine('a warning')\nSet-Content -LiteralPath '%MARKER%' -Value 'x'\nexit 0\n"},
		testPackage{name: "broken", exitCode: 7},
		testPackage{name: "never"},
	)
	// The first package's script needs its marker path, which is only known
	// once the run folder exists.
	scriptPath := filepath.Join(run.root, "first", "1.0.0", "install.ps1")
	rewrite(t, scriptPath, func(s string) string { return strings.Replace(s, "%MARKER%", run.marker("first"), 1) })
	body, _ := os.ReadFile(scriptPath)
	rewrite(t, run.lockPath, func(s string) string {
		// Re-pin the edited script: the first sha256 and sizeBytes in the lock are its own.
		s = regexp.MustCompile(`sha256: [0-9a-f]{64}`).ReplaceAllStringFunc(s, once("sha256: "+sha256Hex(string(body))))
		return regexp.MustCompile(`sizeBytes: \d+`).ReplaceAllStringFunc(s, once("sizeBytes: "+itoa(len(body))))
	})
	writeSidecar(t, run.lockPath)

	config := run.config(true)
	config.ExecutionID = "job-4242"
	config.RunnerVersion = "1.2.3"
	if _, err := NewExecutor(config).Run(); err != nil {
		t.Fatal(err)
	}

	path := filepath.Join(run.evidenceDir, InstallResultFile)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.HasPrefix(string(raw), string(rune(0xFEFF))) {
		t.Error("the result file must not start with a byte order mark")
	}
	if strings.Contains(string(raw), "not-for-the-result-file") || strings.Contains(string(raw), "a warning") {
		t.Error("installer output must not be in the result file")
	}

	// The top-level keys, exactly: a reader may depend on every one of them.
	var keys map[string]json.RawMessage
	if err := json.Unmarshal(raw, &keys); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"schema_version", "command", "execution_id", "runner_version", "lock_sha256", "lock_sidecar",
		"started_at", "finished_at", "outcome", "publication_eligible", "restart_required", "exit_code", "error", "packages"} {
		if _, ok := keys[key]; !ok {
			t.Errorf("result file has no %q", key)
		}
		delete(keys, key)
	}
	if len(keys) != 0 {
		t.Errorf("result file has undeclared keys: %v", keys)
	}

	file := readResultFile(t, path)
	if file.SchemaVersion != 1 || file.Command != "install" || file.ExecutionID != "job-4242" || file.RunnerVersion != "1.2.3" {
		t.Errorf("identity fields: %+v", file)
	}
	if file.LockSHA256 != mustHash(t, run.lockPath) || file.LockSidecar != LockSidecarVerified {
		t.Errorf("lock_sha256 = %q, lock_sidecar = %q", file.LockSHA256, file.LockSidecar)
	}
	if !utcToTheSecond.MatchString(file.StartedAt) || !utcToTheSecond.MatchString(file.FinishedAt) {
		t.Errorf("times must be UTC with a Z suffix: %q, %q", file.StartedAt, file.FinishedAt)
	}
	if file.Outcome != OutcomeFailed || file.ExitCode != 10 || file.PublicationEligible || file.RestartRequired {
		t.Errorf("outcome fields: %+v", file)
	}

	// Every package in the lock, in install order.
	if len(file.Packages) != 3 || file.Packages[0].Name != "first" || file.Packages[1].Name != "broken" || file.Packages[2].Name != "never" {
		t.Fatalf("packages: %+v", file.Packages)
	}
	first, broken, never := file.Packages[0], file.Packages[1], file.Packages[2]
	if first.Status != models.PackageStatusSuccess || first.ExitCode == nil || *first.ExitCode != 0 || first.Version != "1.0.0" {
		t.Errorf("first: %+v", first)
	}
	if first.Validation == nil || !first.Validation.Passed || len(first.Files) != 1 || first.Files[0].SizeBytes != int64(len(body)) {
		t.Errorf("first evidence: %+v", first)
	}
	if first.DurationMS <= 0 || first.DurationMS > 120000 {
		t.Errorf("duration_ms = %d; it must be milliseconds", first.DurationMS)
	}
	if broken.Status != models.PackageStatusFailed || broken.ExitCode == nil || *broken.ExitCode != 7 || broken.Error == "" || broken.Validation != nil {
		t.Errorf("broken: %+v", broken)
	}
	if never.Status != models.PackageStatusNotRun || never.ExitCode != nil || never.TimedOut {
		t.Errorf("never: %+v", never)
	}

	// What the installer printed is kept on the machine, beside the result.
	stdout, err := os.ReadFile(filepath.Join(run.evidenceDir, "first", "stdout.log"))
	if err != nil || !strings.Contains(string(stdout), "not-for-the-result-file") {
		t.Errorf("installer stdout not kept: %q, %v", stdout, err)
	}
	if stderr, err := os.ReadFile(filepath.Join(run.evidenceDir, "first", "stderr.log")); err != nil || !strings.Contains(string(stderr), "a warning") {
		t.Errorf("installer stderr not kept: %q, %v", stderr, err)
	}
}

func TestResultFileWhenTheRunStopsBeforeAnyPackage(t *testing.T) {
	run := stagePackages(t, testPackage{name: "only"})
	config := run.config(false)
	config.ElevationCheck = func() bool { return false }
	if _, err := NewExecutor(config).Run(); err != nil {
		t.Fatal(err)
	}
	file := readResultFile(t, filepath.Join(run.evidenceDir, InstallResultFile))
	if file.ExitCode != 12 || file.Outcome != OutcomeFailed || file.Error == "" || file.PublicationEligible {
		t.Errorf("not elevated: %+v", file)
	}
	if file.Packages == nil || len(file.Packages) != 0 {
		t.Errorf("packages must be an empty list, not null: %+v", file.Packages)
	}

	// A staged file that does not match: the result records what was found.
	config = run.config(false)
	staged := filepath.Join(run.root, "only", "1.0.0", "install.ps1")
	rewrite(t, staged, func(s string) string { return s + "# changed\n" })
	if _, err := NewExecutor(config).Run(); err != nil {
		t.Fatal(err)
	}
	file = readResultFile(t, filepath.Join(run.evidenceDir, InstallResultFile))
	if file.ExitCode != 11 || len(file.Packages) != 1 {
		t.Fatalf("integrity: %+v", file)
	}
	only := file.Packages[0]
	if only.Status != models.PackageStatusFailed || only.ExitCode != nil || len(only.Files) != 1 || only.Files[0].SHA256 != mustHash(t, staged) {
		t.Errorf("the record must carry the hash computed from the changed file: %+v", only)
	}
}

func TestVerifyResultFile(t *testing.T) {
	run := stagePackages(t, testPackage{name: "only"})
	if _, err := NewExecutor(run.config(false)).Run(); err != nil {
		t.Fatal(err)
	}
	if _, err := NewExecutor(run.config(false)).Verify(); err != nil {
		t.Fatal(err)
	}
	file := readResultFile(t, filepath.Join(run.evidenceDir, VerifyResultFile))
	if file.Command != "verify" || file.ExitCode != 0 || file.Outcome != OutcomeSuccess || !file.PublicationEligible {
		t.Errorf("verify: %+v", file)
	}
	only := file.Packages[0]
	// Verify runs no installer and hashes no staged file.
	if only.ExitCode != nil || len(only.Files) != 0 || only.Validation == nil || !only.Validation.Passed {
		t.Errorf("verify package record: %+v", only)
	}
}

func TestRestartResultIsNotPublicationEligible(t *testing.T) {
	run := stagePackages(t, testPackage{name: "needsrestart", exitCode: 3010,
		lockExtra: "        timeout: 2m0s\n        restartExitCodes: [3010]\n"})
	if _, err := NewExecutor(run.config(false)).Run(); err != nil {
		t.Fatal(err)
	}
	file := readResultFile(t, filepath.Join(run.evidenceDir, InstallResultFile))
	// Installed, but not yet shown to be installed correctly: verify decides.
	if file.ExitCode != 3010 || file.Outcome != OutcomeSuccess || !file.RestartRequired || file.PublicationEligible {
		t.Errorf("restart: %+v", file)
	}
	if record := file.Packages[0]; !record.RestartRequired || record.ExitCode == nil || *record.ExitCode != 3010 {
		t.Errorf("package record: %+v", record)
	}
}

// once returns a replacer that substitutes only the first match.
func once(replacement string) func(string) string {
	done := false
	return func(match string) string {
		if done {
			return match
		}
		done = true
		return replacement
	}
}

func itoa(n int) string { return strconv.Itoa(n) }

func writeSidecar(t *testing.T, lockPath string) {
	t.Helper()
	if err := integrity.WriteSidecar(lockPath); err != nil {
		t.Fatal(err)
	}
}
