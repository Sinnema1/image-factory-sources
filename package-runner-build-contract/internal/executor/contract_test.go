package executor

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"package-runner/internal/integrity"
	"package-runner/internal/logging"
	"package-runner/internal/models"
)

func TestStagedArtifactPath(t *testing.T) {
	root := filepath.Join("C:", "staging", "packages")
	pkg := func(name, version, filename string) *models.LockPackage {
		return &models.LockPackage{Name: name, Version: version, Artifact: &models.Artifact{
			// The source-side fields must play no part in the staged path.
			Repository: "packages", Path: "./somewhere/else", Filename: filename,
		}}
	}

	for _, filename := range []string{"install.ps1", "/install.ps1"} {
		got, err := stagedArtifactPath(root, pkg("testpkg", "1.0.0", filename))
		want := filepath.Join(root, "testpkg", "1.0.0", "install.ps1")
		if err != nil || got != want {
			t.Errorf("filename %q: got %q, %v; want %q", filename, got, err, want)
		}
	}
	if got, err := stagedArtifactPath(root, pkg("testpkg", "1.0.0", "bin/setup.exe")); err != nil || got != filepath.Join(root, "testpkg", "1.0.0", "bin", "setup.exe") {
		t.Errorf("a file in a subfolder: got %q, %v", got, err)
	}

	refused := []*models.LockPackage{
		pkg("testpkg", "1.0.0", ""),
		pkg("testpkg", "1.0.0", "../other/install.ps1"),
		pkg("testpkg", "1.0.0", `..\other\install.ps1`),
		pkg("testpkg", "1.0.0", `C:\Windows\System32\cmd.exe`),
		pkg("..", "1.0.0", "install.ps1"),
		pkg("testpkg", "", "install.ps1"),
		pkg("testpkg", `1.0\..\..`, "install.ps1"),
	}
	for _, p := range refused {
		if got, err := stagedArtifactPath(root, p); err == nil {
			t.Errorf("name %q version %q filename %q should be refused, got %q", p.Name, p.Version, p.Artifact.Filename, got)
		}
	}
}

// stagedLock writes a lock for one package whose file is staged under root in
// the download-packages layout, and returns the lock path and the marker the
// install script writes.
func stagedLock(t *testing.T, dir, root, validatedPath string) (string, string) {
	t.Helper()
	marker := filepath.Join(dir, "marker.txt")
	body := fmt.Sprintf("Set-Content -LiteralPath '%s' -Value 'installed' -Encoding ASCII\nexit 0\n", marker)
	pkgDir := filepath.Join(root, "testpkg", "1.0.0")
	if err := os.MkdirAll(pkgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pkgDir, "install.ps1"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if validatedPath == "" {
		validatedPath = marker
	}
	lock := fmt.Sprintf(`apiVersion: image.example/v1alpha1
kind: ImageRecipeLock
metadata:
    name: test
    version: 0.0.1
packages:
    - name: testpkg
      version: 1.0.0
      install:
        handler: powershell
        timeout: 2m0s
        successExitCodes: [0]
      validation:
        - handler: file
          parameters:
            path: %q
      artifact:
        repository: packages
        path: ./testpkg/1.0.0
        filename: /install.ps1
        sha256: %s
        sizeBytes: %d
`, validatedPath, sha256Hex(body), len(body))
	lockPath := filepath.Join(dir, "lock.yaml")
	if err := os.WriteFile(lockPath, []byte(lock), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := integrity.WriteSidecar(lockPath); err != nil {
		t.Fatal(err)
	}
	return lockPath, marker
}

func sha256Hex(content string) string {
	sum := sha256.Sum256([]byte(content))
	return hex.EncodeToString(sum[:])
}

// asElevated stands in for an elevated process, which the tests do not have.
func asElevated() bool { return true }

// readResultFile reads a result file as written, refusing any field the
// ResultFile type does not declare.
func readResultFile(t *testing.T, path string) ResultFile {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("result file not written: %v", err)
	}
	var written ResultFile
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&written); err != nil {
		t.Fatalf("result file does not match the declared shape: %v", err)
	}
	return written
}

// readResult returns a result file's packages by name.
func readResult(t *testing.T, path string) map[string]PackageRecord {
	t.Helper()
	packages := map[string]PackageRecord{}
	for _, record := range readResultFile(t, path).Packages {
		packages[record.Name] = record
	}
	return packages
}

func TestInstallFromArtifactRootThenVerify(t *testing.T) {
	dir := t.TempDir()
	// The working directory is deliberately not the staging folder: the file
	// must be found through the artifact root alone.
	root := filepath.Join(dir, "staging", "packages")
	lockPath, marker := stagedLock(t, dir, root, "")
	evidenceDir := filepath.Join(dir, "evidence")
	config := &ExecutorConfig{
		LockPath:     lockPath,
		ArtifactRoot: root,
		EvidenceDir:  evidenceDir,
		ExecutionID:  "exec-1",
		Logger:       logging.NewLogger(logging.LevelInfo),

		ElevationCheck: asElevated,
	}

	// Before the install, verify reports the missing state and installs nothing.
	result, err := NewExecutor(config).Verify()
	if err != nil || result.OverallSuccess {
		t.Fatalf("verify before install should fail cleanly: %+v, %v", result, err)
	}
	if _, statErr := os.Stat(marker); statErr == nil {
		t.Fatal("verify must not install anything")
	}
	before := readResult(t, filepath.Join(evidenceDir, VerifyResultFile))["testpkg"]
	if before.Status != models.PackageStatusValidationFailed || before.Validation == nil || len(before.Validation.Results) != 1 {
		t.Fatalf("verify result before install: %+v", before)
	}

	result, err = NewExecutor(config).Run()
	if err != nil || !result.OverallSuccess {
		t.Fatalf("install from the artifact root should succeed: %+v, %v", result, err)
	}
	if installed := readResult(t, filepath.Join(evidenceDir, InstallResultFile))["testpkg"]; installed.Status != models.PackageStatusSuccess {
		t.Fatalf("install result: %+v", installed)
	}

	result, err = NewExecutor(config).Verify()
	if err != nil || !result.OverallSuccess {
		t.Fatalf("verify after install should succeed: %+v, %v", result, err)
	}
	after := readResult(t, filepath.Join(evidenceDir, VerifyResultFile))["testpkg"]
	if after.Status != models.PackageStatusSuccess || after.Validation.Results[0].Package != "testpkg" {
		t.Fatalf("verify result after install: %+v", after)
	}
}

func TestInstallFailsWhenTheStagedFileIsAbsent(t *testing.T) {
	dir := t.TempDir()
	lockPath, _ := stagedLock(t, dir, filepath.Join(dir, "staging", "packages"), "")
	result, err := NewExecutor(&ExecutorConfig{
		LockPath:     lockPath,
		ArtifactRoot: filepath.Join(dir, "empty"),
		EvidenceDir:  filepath.Join(dir, "evidence"),
		Logger:       logging.NewLogger(logging.LevelInfo),

		ElevationCheck: asElevated,
	}).Run()
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if result.OverallSuccess || !result.IntegrityFailure || len(result.FailedPackages) != 1 {
		t.Fatalf("a package whose file is not staged must be an integrity failure: %+v", result)
	}
}

func TestRunReportsAnErrorWhenTheResultCannotBeWritten(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "staging", "packages")
	lockPath, _ := stagedLock(t, dir, root, "")
	// A file where the evidence directory should be.
	blocked := filepath.Join(dir, "evidence")
	if err := os.WriteFile(blocked, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := NewExecutor(&ExecutorConfig{
		LockPath:     lockPath,
		ArtifactRoot: root,
		EvidenceDir:  blocked,
		Logger:       logging.NewLogger(logging.LevelInfo),
	}).Verify()
	if err == nil {
		t.Fatal("a run that cannot write its result file must return an error")
	}
}
