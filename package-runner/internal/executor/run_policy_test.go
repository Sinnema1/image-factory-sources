package executor

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"package-runner/internal/integrity"
	"package-runner/internal/logging"
	"package-runner/internal/models"
)

// testPackage describes one package for a multi-package lock. Its install
// script writes a marker file and then exits with exitCode; unless
// noValidation is set, its validation is that the marker exists.
type testPackage struct {
	name         string
	exitCode     int
	script       string // replaces the default script when set
	lockExtra    string // extra lines for the install block, already indented
	dependencies []string
	noValidation bool
}

type policyRun struct {
	dir         string
	lockPath    string
	root        string
	evidenceDir string
}

func (r policyRun) marker(name string) string { return filepath.Join(r.dir, name+".marker") }

func (r policyRun) installed(name string) bool {
	_, err := os.Stat(r.marker(name))
	return err == nil
}

func (r policyRun) config(stopOnFailure bool) *ExecutorConfig {
	return &ExecutorConfig{
		LockPath:       r.lockPath,
		ArtifactRoot:   r.root,
		EvidenceDir:    r.evidenceDir,
		Logger:         logging.NewLogger(logging.LevelInfo),
		StopOnFailure:  stopOnFailure,
		ElevationCheck: asElevated,
	}
}

// stagePackages stages the packages and writes their lock and its sidecar.
// Packages install in the order given.
func stagePackages(t *testing.T, packages ...testPackage) policyRun {
	t.Helper()
	dir := t.TempDir()
	run := policyRun{
		dir:         dir,
		lockPath:    filepath.Join(dir, "lock.yaml"),
		root:        filepath.Join(dir, "staging", "packages"),
		evidenceDir: filepath.Join(dir, "evidence"),
	}

	lock := "apiVersion: image.example/v1alpha1\nkind: ImageRecipeLock\nmetadata:\n    name: test\n    version: 0.0.1\npackages:\n"
	for i, pkg := range packages {
		body := pkg.script
		if body == "" {
			body = fmt.Sprintf("Set-Content -LiteralPath '%s' -Value 'installed' -Encoding ASCII\nexit %d\n", run.marker(pkg.name), pkg.exitCode)
		}
		pkgDir := filepath.Join(run.root, pkg.name, "1.0.0")
		if err := os.MkdirAll(pkgDir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(pkgDir, "install.ps1"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}

		lock += fmt.Sprintf("    - name: %s\n      version: 1.0.0\n      installOrder: %d\n", pkg.name, (i+1)*10)
		if len(pkg.dependencies) > 0 {
			lock += "      dependencies: [" + strings.Join(pkg.dependencies, ", ") + "]\n"
		}
		lock += "      install:\n        handler: powershell\n        successExitCodes: [0]\n"
		if pkg.lockExtra != "" {
			lock += pkg.lockExtra
		} else {
			lock += "        timeout: 2m0s\n"
		}
		if !pkg.noValidation {
			lock += fmt.Sprintf("      validation:\n        - handler: file\n          parameters:\n            path: %q\n", run.marker(pkg.name))
		}
		lock += fmt.Sprintf("      artifact:\n        filename: install.ps1\n        sha256: %s\n        sizeBytes: %d\n", sha256Hex(body), len(body))
	}
	if err := os.WriteFile(run.lockPath, []byte(lock), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := integrity.WriteSidecar(run.lockPath); err != nil {
		t.Fatal(err)
	}
	return run
}

func statuses(t *testing.T, run policyRun, fileName string) map[string]string {
	t.Helper()
	got := map[string]string{}
	for name, result := range readResult(t, filepath.Join(run.evidenceDir, fileName)) {
		got[name] = result.Status
	}
	return got
}

func TestRestartIsReportedAndValidatedOnlyByVerify(t *testing.T) {
	run := stagePackages(t,
		testPackage{name: "plain"},
		testPackage{name: "needsrestart", exitCode: 3010, lockExtra: "        timeout: 2m0s\n        restartExitCodes: [3010]\n"},
	)
	result, err := NewExecutor(run.config(false)).Run()
	if err != nil {
		t.Fatal(err)
	}
	if !result.OverallSuccess || !result.RestartRequired || !reflect.DeepEqual(result.RestartPackages, []string{"needsrestart"}) {
		t.Fatalf("unexpected result: %+v", result)
	}
	installed := readResult(t, filepath.Join(run.evidenceDir, InstallResultFile))
	if got := installed["needsrestart"]; got.Status != models.PackageStatusRestart || !got.RestartRequired || got.Validation != nil {
		t.Fatalf("a package that needs a restart is not validated by install: %+v", got)
	}
	if installed["plain"].Status != models.PackageStatusSuccess {
		t.Fatalf("plain: %+v", installed["plain"])
	}

	// After the restart, verify gives the package its final status.
	verified, err := NewExecutor(run.config(false)).Verify()
	if err != nil || !verified.OverallSuccess || verified.RestartRequired {
		t.Fatalf("verify: %+v, %v", verified, err)
	}
	if got := statuses(t, run, VerifyResultFile); got["needsrestart"] != models.PackageStatusSuccess {
		t.Fatalf("verify statuses: %v", got)
	}
}

func TestRestartCodeWinsWhenAlsoListedAsSuccess(t *testing.T) {
	run := stagePackages(t, testPackage{name: "both", exitCode: 3010,
		lockExtra: "        timeout: 2m0s\n        restartExitCodes: [3010]\n"})
	rewrite(t, run.lockPath, func(s string) string {
		return strings.Replace(s, "successExitCodes: [0]", "successExitCodes: [0, 3010]", 1)
	})
	if err := integrity.WriteSidecar(run.lockPath); err != nil {
		t.Fatal(err)
	}
	result, err := NewExecutor(run.config(false)).Run()
	if err != nil || !result.RestartRequired {
		t.Fatalf("the restart must not be lost: %+v, %v", result, err)
	}
}

func TestAFailureWinsOverARestart(t *testing.T) {
	run := stagePackages(t,
		testPackage{name: "needsrestart", exitCode: 3010, lockExtra: "        timeout: 2m0s\n        restartExitCodes: [3010]\n"},
		testPackage{name: "broken", exitCode: 7},
	)
	result, err := NewExecutor(run.config(false)).Run()
	if err != nil {
		t.Fatal(err)
	}
	if result.OverallSuccess || result.RestartRequired || !reflect.DeepEqual(result.FailedPackages, []string{"broken"}) {
		t.Fatalf("unexpected result: %+v", result)
	}
}

func TestStopOnFailureEndsAtTheFirstFailure(t *testing.T) {
	run := stagePackages(t,
		testPackage{name: "first"},
		testPackage{name: "broken", exitCode: 7},
		testPackage{name: "third"},
		testPackage{name: "fourth"},
	)
	result, err := NewExecutor(run.config(true)).Run()
	if err != nil {
		t.Fatal(err)
	}
	if result.OverallSuccess || result.PublicationEligible || !reflect.DeepEqual(result.NotRunPackages, []string{"third", "fourth"}) {
		t.Fatalf("unexpected result: %+v", result)
	}
	if run.installed("third") || run.installed("fourth") {
		t.Fatal("packages after the failure must not be installed")
	}
	want := map[string]string{
		"first":  models.PackageStatusSuccess,
		"broken": models.PackageStatusFailed,
		"third":  models.PackageStatusNotRun,
		"fourth": models.PackageStatusNotRun,
	}
	if got := statuses(t, run, InstallResultFile); !reflect.DeepEqual(got, want) {
		t.Fatalf("statuses = %v, want %v", got, want)
	}
}

func TestInstallCarriesOnAfterAFailureButBlocksDependents(t *testing.T) {
	run := stagePackages(t,
		testPackage{name: "broken", exitCode: 7},
		testPackage{name: "dependent", dependencies: []string{"broken"}},
		testPackage{name: "transitive", dependencies: []string{"dependent"}},
		testPackage{name: "unrelated"},
	)
	result, err := NewExecutor(run.config(false)).Run()
	if err != nil {
		t.Fatal(err)
	}
	if result.OverallSuccess || result.PublicationEligible || result.ExitCode() != ExitPackageFailed || result.Outcome() != OutcomeFailed {
		t.Fatalf("unexpected result: %+v", result)
	}
	if run.installed("dependent") || run.installed("transitive") {
		t.Fatal("a package whose dependency did not install must not be installed")
	}
	if !run.installed("unrelated") {
		t.Fatal("a package unrelated to the failure must still be installed")
	}
	if len(result.NotRunPackages) != 0 {
		t.Fatalf("nothing is skipped by default: %v", result.NotRunPackages)
	}
	want := map[string]string{
		"broken":     models.PackageStatusFailed,
		"dependent":  models.PackageStatusBlocked,
		"transitive": models.PackageStatusBlocked,
		"unrelated":  models.PackageStatusSuccess,
	}
	if got := statuses(t, run, InstallResultFile); !reflect.DeepEqual(got, want) {
		t.Fatalf("statuses = %v, want %v", got, want)
	}
}

func TestAPackageWithNoValidationIsNotASuccess(t *testing.T) {
	run := stagePackages(t, testPackage{name: "unchecked", noValidation: true})
	result, err := NewExecutor(run.config(false)).Run()
	if err != nil {
		t.Fatal(err)
	}
	if result.OverallSuccess || !reflect.DeepEqual(result.FailedPackages, []string{"unchecked"}) {
		t.Fatalf("unexpected result: %+v", result)
	}
	got := readResult(t, filepath.Join(run.evidenceDir, InstallResultFile))["unchecked"]
	if got.Status != models.PackageStatusValidationFailed || got.Validation == nil || got.Validation.Passed || len(got.Validation.Results) != 1 || got.Validation.Results[0].Error == "" {
		t.Fatalf("the result must say why: %+v", got)
	}

	verified, err := NewExecutor(run.config(false)).Verify()
	if err != nil || verified.OverallSuccess {
		t.Fatalf("verify must apply the same rule: %+v, %v", verified, err)
	}
}

func TestInstallTimeoutIsEnforced(t *testing.T) {
	run := stagePackages(t,
		testPackage{name: "slow", script: "Start-Sleep -Seconds 60\nexit 0\n", lockExtra: "        timeout: 3s\n"},
		testPackage{name: "after"},
	)
	started := time.Now()
	result, err := NewExecutor(run.config(true)).Run()
	elapsed := time.Since(started)
	if err != nil {
		t.Fatal(err)
	}
	if elapsed > 30*time.Second {
		t.Fatalf("the install ran for %v; the 3s timeout was not enforced", elapsed)
	}
	if result.OverallSuccess || !reflect.DeepEqual(result.FailedPackages, []string{"slow"}) {
		t.Fatalf("unexpected result: %+v", result)
	}
	got := readResult(t, filepath.Join(run.evidenceDir, InstallResultFile))
	if slow := got["slow"]; slow.Status != models.PackageStatusTimeout || !slow.TimedOut || slow.ExitCode != nil {
		t.Fatalf("slow: %+v", slow)
	}
	if got["after"].Status != models.PackageStatusNotRun {
		t.Fatalf("after: %+v", got["after"])
	}
}
