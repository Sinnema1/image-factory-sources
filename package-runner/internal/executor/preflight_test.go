package executor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"package-runner/internal/logging"
	"package-runner/internal/models"
)

// preflightCase stages one package, lets the test damage something, runs
// install, and returns the result and the marker the install would write.
func preflightCase(t *testing.T, elevated bool, damage func(lockPath, stagedFile string)) (*ExecutionResult, string, string) {
	t.Helper()
	dir := t.TempDir()
	root := filepath.Join(dir, "staging", "packages")
	lockPath, marker := stagedLock(t, dir, root, "")
	if damage != nil {
		damage(lockPath, filepath.Join(root, "testpkg", "1.0.0", "install.ps1"))
	}
	evidenceDir := filepath.Join(dir, "evidence")
	result, err := NewExecutor(&ExecutorConfig{
		LockPath:       lockPath,
		ArtifactRoot:   root,
		EvidenceDir:    evidenceDir,
		Logger:         logging.NewLogger(logging.LevelInfo),
		ElevationCheck: func() bool { return elevated },
	}).Run()
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(evidenceDir, InstallResultFile)); statErr != nil {
		t.Fatalf("the result file must be written whatever the outcome: %v", statErr)
	}
	return result, marker, evidenceDir
}

func mustNotHaveInstalled(t *testing.T, marker string) {
	t.Helper()
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("nothing may be installed after a failed preflight check")
	}
}

func rewrite(t *testing.T, path string, change func(string) string) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(change(string(data))), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestInstallRefusesToRunWithoutElevation(t *testing.T) {
	result, marker, _ := preflightCase(t, false, nil)
	if !result.NotElevated || result.IntegrityFailure || result.OverallSuccess || result.Error == "" {
		t.Fatalf("unexpected result: %+v", result)
	}
	mustNotHaveInstalled(t, marker)
}

func TestElevationIsCheckedBeforeTheLock(t *testing.T) {
	// Both are wrong; the earlier check must be the one reported.
	result, _, _ := preflightCase(t, false, func(lockPath, _ string) {
		os.Remove(lockPath + ".sha256")
	})
	if !result.NotElevated || result.IntegrityFailure {
		t.Fatalf("unexpected result: %+v", result)
	}
}

func TestInstallIntegrityFailures(t *testing.T) {
	cases := map[string]func(t *testing.T) func(lockPath, stagedFile string){
		"the lock changed after the sidecar was written": func(t *testing.T) func(string, string) {
			return func(lockPath, _ string) {
				rewrite(t, lockPath, func(s string) string { return s + "\n# changed\n" })
			}
		},
		"the sidecar is not a hash": func(t *testing.T) func(string, string) {
			return func(lockPath, _ string) {
				rewrite(t, lockPath+".sha256", func(string) string { return "not a hash\n" })
			}
		},
		"the staged file changed": func(t *testing.T) func(string, string) {
			return func(_, stagedFile string) {
				// Same length, so only the hash can catch it.
				rewrite(t, stagedFile, func(s string) string { return strings.Replace(s, "installed", "INSTALLED", 1) })
			}
		},
		"the staged file is a different size": func(t *testing.T) func(string, string) {
			return func(_, stagedFile string) {
				rewrite(t, stagedFile, func(s string) string { return s + "# longer\n" })
			}
		},
		"the staged file is missing": func(t *testing.T) func(string, string) {
			return func(_, stagedFile string) { os.Remove(stagedFile) }
		},
	}
	for name, damage := range cases {
		t.Run(name, func(t *testing.T) {
			result, marker, _ := preflightCase(t, true, damage(t))
			if !result.IntegrityFailure || result.NotElevated || result.OverallSuccess || result.Error == "" {
				t.Fatalf("unexpected result: %+v", result)
			}
			mustNotHaveInstalled(t, marker)
		})
	}
}

func TestInstallRefusesALockEntryWithNoHash(t *testing.T) {
	// The lock and its sidecar agree, so only the missing hash is wrong.
	dir := t.TempDir()
	root := filepath.Join(dir, "staging", "packages")
	lockPath, marker := stagedLock(t, dir, root, "")
	rewrite(t, lockPath, func(s string) string {
		lines := strings.Split(s, "\n")
		kept := lines[:0]
		for _, line := range lines {
			if !strings.Contains(line, "sha256:") {
				kept = append(kept, line)
			}
		}
		return strings.Join(kept, "\n")
	})
	if err := os.WriteFile(lockPath+".sha256", []byte(mustHash(t, lockPath)+"  lock.yaml\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	result, err := NewExecutor(&ExecutorConfig{
		LockPath:       lockPath,
		ArtifactRoot:   root,
		EvidenceDir:    filepath.Join(dir, "evidence"),
		Logger:         logging.NewLogger(logging.LevelInfo),
		ElevationCheck: asElevated,
	}).Run()
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !result.IntegrityFailure {
		t.Fatalf("an entry with no hash cannot be verified, so it must not run: %+v", result)
	}
	mustNotHaveInstalled(t, marker)
}

func mustHash(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return sha256Hex(string(data))
}

func TestInstallRecordsTheComputedHashOfWhatRan(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "staging", "packages")
	lockPath, _ := stagedLock(t, dir, root, "")
	evidenceDir := filepath.Join(dir, "evidence")
	result, err := NewExecutor(&ExecutorConfig{
		LockPath:       lockPath,
		ArtifactRoot:   root,
		EvidenceDir:    evidenceDir,
		Logger:         logging.NewLogger(logging.LevelInfo),
		ElevationCheck: asElevated,
	}).Run()
	if err != nil || !result.OverallSuccess {
		t.Fatalf("Run: %+v, %v", result, err)
	}
	if result.LockSHA256 != mustHash(t, lockPath) {
		t.Errorf("lock hash not recorded: %q", result.LockSHA256)
	}
	installed := readResult(t, filepath.Join(evidenceDir, InstallResultFile))["testpkg"]
	if want := mustHash(t, filepath.Join(root, "testpkg", "1.0.0", "install.ps1")); len(installed.Files) != 1 || installed.Files[0].SHA256 != want || installed.Files[0].Path != "install.ps1" {
		t.Errorf("computed file record = %+v, want hash %q", installed.Files, want)
	}
}

func TestVerifyChecksTheSidecarButNotTheStagedFiles(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "staging", "packages")
	lockPath, _ := stagedLock(t, dir, root, "")
	config := &ExecutorConfig{
		LockPath:    lockPath,
		EvidenceDir: filepath.Join(dir, "evidence"),
		Logger:      logging.NewLogger(logging.LevelInfo),
		// Verify installs nothing, so it must not need elevation.
		ElevationCheck: func() bool { return false },
	}

	// The staged files are gone: verify still runs, and fails only because
	// nothing was installed.
	if err := os.RemoveAll(root); err != nil {
		t.Fatal(err)
	}
	result, err := NewExecutor(config).Verify()
	if err != nil || result.IntegrityFailure || result.NotElevated {
		t.Fatalf("verify must not need the staged files or elevation: %+v, %v", result, err)
	}
	if got := readResult(t, filepath.Join(dir, "evidence", VerifyResultFile))["testpkg"]; got.Status != models.PackageStatusValidationFailed {
		t.Fatalf("verify result: %+v", got)
	}

	rewrite(t, lockPath+".sha256", func(string) string { return strings.Repeat("0", 64) + "  lock.yaml\n" })
	result, err = NewExecutor(config).Verify()
	if err != nil || !result.IntegrityFailure {
		t.Fatalf("verify must refuse a lock that does not match its sidecar: %+v, %v", result, err)
	}
}

func TestALockWithNoSidecarInstallsAndSaysSo(t *testing.T) {
	result, marker, evidenceDir := preflightCase(t, true, func(lockPath, _ string) {
		os.Remove(lockPath + ".sha256")
	})
	if !result.OverallSuccess || result.IntegrityFailure || result.LockSidecar != LockSidecarAbsent {
		t.Fatalf("a lock with no sidecar must install: %+v", result)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatal("the package must have been installed")
	}
	file := readResultFile(t, filepath.Join(evidenceDir, InstallResultFile))
	// The hash is still recorded, so the result says which lock was used.
	if file.LockSidecar != LockSidecarAbsent || len(file.LockSHA256) != 64 {
		t.Fatalf("lock_sidecar = %q, lock_sha256 = %q", file.LockSidecar, file.LockSHA256)
	}
}
