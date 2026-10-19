package executor

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"package-runner/internal/models"
)

// Exit codes of the install and verify commands. They are part of the result
// file as well as the process's exit status, so they are decided here.
const (
	ExitSuccess         = 0
	ExitPackageFailed   = 10   // a package failed to install or to validate
	ExitIntegrity       = 11   // the lock or a staged file is not what was pinned
	ExitNotElevated     = 12   // the process cannot install machine-wide software
	ExitRestartRequired = 3010 // everything installed, and a restart is needed
)

// Outcomes written to the result file.
const (
	OutcomeSuccess = "success"
	OutcomeFailed  = "failed"
)

// Whether the lock was compared with a sidecar.
const (
	LockSidecarVerified = "verified"
	LockSidecarAbsent   = "absent"
)

// ResultSchemaVersion is bumped when the result file changes shape.
const ResultSchemaVersion = 1

// ExitCode is the exit status for the run. The checks that stop a run before
// any package is handled come first, in the order they are made; then any
// failure; and a restart only when nothing failed.
func (r *ExecutionResult) ExitCode() int {
	switch {
	case r.NotElevated:
		return ExitNotElevated
	case r.IntegrityFailure:
		return ExitIntegrity
	case !r.OverallSuccess:
		return ExitPackageFailed
	case r.RestartRequired:
		return ExitRestartRequired
	default:
		return ExitSuccess
	}
}

// Outcome is the run's outcome in the result file's vocabulary.
func (r *ExecutionResult) Outcome() string {
	if r.OverallSuccess {
		return OutcomeSuccess
	}
	return OutcomeFailed
}

// ResultFile is what install and verify write into the evidence directory.
// Field names are snake_case throughout, times are UTC, and durations are
// milliseconds. Installer output is deliberately not part of it: an installer
// can print anything, and this file is copied into build artifacts. The
// output is kept beside it, in the package's own folder in the evidence
// directory.
type ResultFile struct {
	SchemaVersion       int             `json:"schema_version"`
	Command             string          `json:"command"`
	ExecutionID         string          `json:"execution_id"`
	RunnerVersion       string          `json:"runner_version"`
	LockSHA256          string          `json:"lock_sha256"`
	LockSidecar         string          `json:"lock_sidecar"`
	StartedAt           string          `json:"started_at"`
	FinishedAt          string          `json:"finished_at"`
	Outcome             string          `json:"outcome"`
	PublicationEligible bool            `json:"publication_eligible"`
	RestartRequired     bool            `json:"restart_required"`
	ExitCode            int             `json:"exit_code"`
	Error               string          `json:"error"`
	Packages            []PackageRecord `json:"packages"`
}

// PackageRecord is one package's part of the result file.
type PackageRecord struct {
	Name    string `json:"name"`
	Version string `json:"version"`
	Status  string `json:"status"`
	// ExitCode is the installer's exit code, or null if no installer ran.
	ExitCode        *int              `json:"exit_code"`
	DurationMS      int64             `json:"duration_ms"`
	TimedOut        bool              `json:"timed_out"`
	RestartRequired bool              `json:"restart_required"`
	Files           []FileRecord      `json:"files"`
	Validation      *ValidationRecord `json:"validation"`
	Error           string            `json:"error"`
}

// FileRecord is a staged file as it was found, with the hash and size
// computed from it, not the values the lock declares.
type FileRecord struct {
	Path      string `json:"path"`
	SHA256    string `json:"sha256"`
	SizeBytes int64  `json:"size_bytes"`
}

// ValidationRecord is the outcome of a package's declared validation.
type ValidationRecord struct {
	Passed  bool                        `json:"passed"`
	Results []models.ValidationEvidence `json:"results"`
}

// formatTime writes a time as UTC to the second, with a Z suffix.
func formatTime(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05Z")
}

// packageRecord converts one package's internal result.
func packageRecord(pkg *models.LockPackage, result *models.ExecutionResult, file *FileRecord) PackageRecord {
	record := PackageRecord{
		Name:            pkg.Name,
		Version:         pkg.Version,
		Status:          result.Status,
		DurationMS:      result.Duration.Milliseconds(),
		TimedOut:        result.Timeout,
		RestartRequired: result.Status == models.PackageStatusRestart,
		Files:           []FileRecord{},
		Error:           result.Error,
	}
	if result.Ran {
		exitCode := result.ExitCode
		record.ExitCode = &exitCode
	}
	if file != nil {
		record.Files = append(record.Files, *file)
	}
	if result.Validations != nil {
		passed := len(result.Validations) > 0
		for _, validation := range result.Validations {
			if validation.Result != models.ValidationResultPassed {
				passed = false
			}
		}
		record.Validation = &ValidationRecord{Passed: passed, Results: result.Validations}
	}
	return record
}

// writeResult writes the result file. Packages appear in install order; a
// package the run has no result for is left out, which happens only when the
// run stopped before it read the lock.
func (e *Executor) writeResult(fileName string, overall *ExecutionResult, packageResults map[string]*models.ExecutionResult) error {
	command := "install"
	if fileName == VerifyResultFile {
		command = "verify"
	}

	file := ResultFile{
		SchemaVersion:       ResultSchemaVersion,
		Command:             command,
		ExecutionID:         e.config.ExecutionID,
		RunnerVersion:       e.config.RunnerVersion,
		LockSHA256:          overall.LockSHA256,
		LockSidecar:         overall.LockSidecar,
		StartedAt:           formatTime(e.startedAt),
		FinishedAt:          formatTime(time.Now()),
		Outcome:             overall.Outcome(),
		PublicationEligible: overall.PublicationEligible && overall.ExitCode() == ExitSuccess,
		RestartRequired:     overall.RestartRequired,
		ExitCode:            overall.ExitCode(),
		Error:               overall.Error,
		Packages:            []PackageRecord{},
	}
	for _, pkg := range e.order {
		result, ok := packageResults[pkg.Name]
		if !ok {
			continue
		}
		var staged *FileRecord
		if found, ok := e.staged[pkg.Name]; ok {
			staged = &found
		}
		file.Packages = append(file.Packages, packageRecord(pkg, result, staged))
	}

	data, err := json.MarshalIndent(file, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal result: %w", err)
	}
	if err := os.MkdirAll(e.config.EvidenceDir, 0755); err != nil {
		return fmt.Errorf("create evidence directory: %w", err)
	}
	path := filepath.Join(e.config.EvidenceDir, fileName)
	// Written without a byte order mark, so jq reads it.
	if err := os.WriteFile(path, append(data, '\n'), 0644); err != nil {
		return fmt.Errorf("write result file %s: %w", path, err)
	}
	return nil
}

// saveInstallerOutput keeps what an installer printed in the package's folder
// in the evidence directory. It is not fatal if it cannot be written: the
// result file is the record, and this is for a person diagnosing a failure.
func (e *Executor) saveInstallerOutput(dir string, pkg *models.LockPackage, result *models.ExecutionResult) {
	if result == nil {
		return
	}
	for name, content := range map[string]string{"stdout.log": result.Stdout, "stderr.log": result.Stderr} {
		if content == "" {
			continue
		}
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0644); err != nil {
			e.logger.Warn("Could not save installer output", map[string]interface{}{
				"package": pkg.Name,
				"file":    name,
				"error":   err.Error(),
			})
		}
	}
}
