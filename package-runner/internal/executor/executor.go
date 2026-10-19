// Package executor provides package installation execution functionality
package executor

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"package-runner/internal/handlers"
	"package-runner/internal/integrity"
	"package-runner/internal/logging"
	"package-runner/internal/models"
	"package-runner/internal/pathutil"
	"package-runner/internal/validators"
)

// ExecutorConfig contains configuration for the Executor
type ExecutorConfig struct {
	LockPath string
	// ArtifactRoot is the directory the package files were staged under, as
	// <ArtifactRoot>/<name>/<version>/<filename>. Empty keeps the older
	// behaviour of resolving the lock's repository and path against the
	// working directory.
	ArtifactRoot string
	EvidenceDir  string
	ExecutionID  string
	Logger       *logging.Logger
	// StopOnFailure ends the run at the first failed package. The default is
	// to carry on, so one run reports every package that fails; a package
	// whose dependency did not install is never installed either way.
	StopOnFailure bool
	// RunnerVersion is written to the result file.
	RunnerVersion string
	// ElevationCheck replaces the check for an elevated process. Nil uses the
	// real one. It exists so the install path can be tested without elevation.
	ElevationCheck func() bool
}

// ExecutionResult contains the overall execution results
type ExecutionResult struct {
	OverallSuccess     bool
	SuccessfulPackages []string
	FailedPackages     []string
	BlockedPackages    []string
	// RestartPackages installed with an exit code that asks for a restart.
	// They are not validated until verify runs after it. NotRunPackages were
	// never reached, because the run stopped at an earlier failure.
	RestartPackages []string
	NotRunPackages  []string
	// RestartRequired is true when nothing failed and at least one package
	// needs a restart. A failure always wins over a restart.
	RestartRequired     bool
	PublicationEligible bool
	// NotElevated and IntegrityFailure say why nothing was installed: the
	// process could not install machine-wide software, or the lock or a
	// staged file was not what was pinned. Error carries the reason.
	NotElevated      bool
	IntegrityFailure bool
	Error            string
	// LockSHA256 is the hash computed for the lock, once it has been read.
	// LockSidecar says whether it was compared with a sidecar: "verified", or
	// "absent" when the lock came with none.
	LockSHA256  string
	LockSidecar string
}

// Executor executes package installations
type Executor struct {
	config         *ExecutorConfig
	logger         *logging.Logger
	lock           *models.ImageRecipeLock
	handlerFactory *handlers.Factory
	// staged holds what was found for each package's staged file; verified
	// marks the ones that matched the lock in this run.
	staged   map[string]FileRecord
	verified map[string]bool
	// order is the lock's packages in install order, and startedAt is when
	// the run began. Both go into the result file.
	order     []*models.LockPackage
	startedAt time.Time
}

// defaultInstallTimeout applies to a package whose lock entry sets no timeout.
// It is the longest default any handler declares.
const defaultInstallTimeout = 30 * time.Minute

// Result files written into the evidence directory. The image build fetches
// them by these exact names.
const (
	InstallResultFile = "install-result.json"
	VerifyResultFile  = "install-result-verify.json"
)

// getArtifactPath constructs the full artifact path from a package's artifact info
func (e *Executor) getArtifactPath(pkg *models.LockPackage) (string, error) {
	if pkg.Artifact == nil {
		return "", nil
	}
	if e.config.ArtifactRoot != "" {
		return stagedArtifactPath(e.config.ArtifactRoot, pkg)
	}
	// Windows env vars expanded
	pkg.Artifact.Filename = pathutil.ExpandWindowsEnv(pkg.Artifact.Filename)
	pkg.Artifact.Repository = pathutil.ExpandWindowsEnv(pkg.Artifact.Repository)
	pkg.Artifact.Path = pathutil.ExpandWindowsEnv(pkg.Artifact.Path)

	// For now, use the filename as the path (or full path if already absolute)
	if filepath.IsAbs(pkg.Artifact.Filename) {
		return pkg.Artifact.Filename, nil
	}
	// Combine repository, path, and filename if available
	var artifactPath string
	if pkg.Artifact.Repository != "" && pkg.Artifact.Path != "" {
		artifactPath = filepath.Join(pkg.Artifact.Repository, pkg.Artifact.Path, pkg.Artifact.Filename)
	} else if pkg.Artifact.Path != "" {
		artifactPath = filepath.Join(pkg.Artifact.Path, pkg.Artifact.Filename)
	} else {
		artifactPath = pkg.Artifact.Filename
	}
	return artifactPath, nil
}

// stagedArtifactPath locates a package's file under an artifact root, in the
// layout download-packages writes: <root>/<name>/<version>/<filename>. The
// lock's repository and path say where the file came from on the source side
// and play no part here. A leading slash on the filename is tolerated, as
// download-packages tolerates it; anything that would leave the package's own
// folder is refused, because the lock is the only thing naming what runs.
func stagedArtifactPath(root string, pkg *models.LockPackage) (string, error) {
	filename := strings.TrimLeft(filepath.ToSlash(pkg.Artifact.Filename), "/")
	if filename == "" {
		return "", fmt.Errorf("package %s has no artifact filename", pkg.Name)
	}
	if strings.Contains(filename, ":") || filepath.IsAbs(filename) {
		return "", fmt.Errorf("artifact filename for package %s must be relative: %s", pkg.Name, pkg.Artifact.Filename)
	}
	for _, part := range strings.Split(filename, "/") {
		if part == ".." {
			return "", fmt.Errorf("artifact filename for package %s must not contain ..: %s", pkg.Name, pkg.Artifact.Filename)
		}
	}
	for _, folder := range []string{pkg.Name, pkg.Version} {
		if folder == "" || folder == "." || folder == ".." || strings.ContainsAny(folder, "/:"+string(filepath.Separator)) {
			return "", fmt.Errorf("package %s: name and version must be usable as folder names, got %q", pkg.Name, folder)
		}
	}
	return filepath.Join(root, pkg.Name, pkg.Version, filepath.FromSlash(filename)), nil
}

// NewExecutor creates a new Executor instance
func NewExecutor(config *ExecutorConfig) *Executor {
	return &Executor{
		config:         config,
		logger:         config.Logger,
		handlerFactory: handlers.NewFactory(config.Logger),
		staged:         make(map[string]FileRecord),
		verified:       make(map[string]bool),
		startedAt:      time.Now(),
	}
}

// newResult returns a result for a run in which nothing has failed yet.
func newResult() *ExecutionResult {
	return &ExecutionResult{
		OverallSuccess:      true,
		SuccessfulPackages:  []string{},
		FailedPackages:      []string{},
		BlockedPackages:     []string{},
		RestartPackages:     []string{},
		NotRunPackages:      []string{},
		PublicationEligible: true,
	}
}

// finish writes the result file and returns the result. A run that leaves no
// result file has not reported, so failing to write it is an error, not a
// warning: the caller must not exit 0.
func (e *Executor) finish(fileName string, result *ExecutionResult, packageResults map[string]*models.ExecutionResult) (*ExecutionResult, error) {
	if err := e.writeResult(fileName, result, packageResults); err != nil {
		e.logger.Error("Failed to save evidence", map[string]interface{}{
			"error": err.Error(),
		})
		return result, fmt.Errorf("failed to save evidence: %w", err)
	}
	return result, nil
}

// stop records why a run did not get as far as installing or checking
// anything, logs it, and writes the result file.
func (e *Executor) stop(fileName string, result *ExecutionResult, packageResults map[string]*models.ExecutionResult, reason error) (*ExecutionResult, error) {
	result.OverallSuccess = false
	result.PublicationEligible = false
	result.Error = reason.Error()
	e.logger.Error("Run stopped before any package was handled", map[string]interface{}{
		"error":            result.Error,
		"notElevated":      result.NotElevated,
		"integrityFailure": result.IntegrityFailure,
	})
	return e.finish(fileName, result, packageResults)
}

// loadPinnedLock checks the lock against its sidecar, if it has one, and then
// loads it. Any failure here is an integrity failure: the run has nothing it
// can trust.
//
// The sidecar is optional. A lock generated and used inside one pipeline is
// already protected where it is stored, so a missing sidecar is recorded and
// not refused. One that is present must match. The lock's hash is computed
// and recorded either way, so the result always says which lock was used.
func (e *Executor) loadPinnedLock(result *ExecutionResult) error {
	lockSHA256, err := integrity.VerifySidecar(e.config.LockPath)
	switch {
	case err == nil:
		result.LockSidecar = LockSidecarVerified
	case errors.Is(err, integrity.ErrNoSidecar):
		result.LockSidecar = LockSidecarAbsent
		lockSHA256, _, err = integrity.FileSHA256(e.config.LockPath)
		if err != nil {
			result.IntegrityFailure = true
			return fmt.Errorf("the lock could not be read: %w", err)
		}
		e.logger.Info("Lock has no sidecar; its hash is recorded but was not compared", map[string]interface{}{
			"lockSha256": lockSHA256,
		})
	default:
		result.LockSHA256 = lockSHA256
		result.IntegrityFailure = true
		return err
	}
	result.LockSHA256 = lockSHA256
	lock, err := models.LoadImageRecipeLock(e.config.LockPath)
	if err != nil {
		result.IntegrityFailure = true
		return fmt.Errorf("failed to load lock file: %w", err)
	}
	e.lock = lock
	return nil
}

// Run executes the installation workflow from the lock file
func (e *Executor) Run() (*ExecutionResult, error) {
	e.startedAt = time.Now()
	result := newResult()
	packageResults := make(map[string]*models.ExecutionResult)

	// The checks below run in this order on purpose, and each has its own
	// exit code: elevation first, then the lock, then every staged file.
	// Nothing is installed unless all of them pass.
	if !e.elevated() {
		result.NotElevated = true
		return e.stop(InstallResultFile, result, packageResults, errors.New("the process is not elevated"))
	}

	if err := e.loadPinnedLock(result); err != nil {
		return e.stop(InstallResultFile, result, packageResults, err)
	}
	lock := e.lock

	// Sort packages by install order
	packages := make([]*models.LockPackage, len(lock.Packages))
	copy(packages, lock.Packages)
	sort.SliceStable(packages, func(i, j int) bool {
		return packages[i].InstallOrder < packages[j].InstallOrder
	})
	e.order = packages

	// Recompute the size and hash of every staged file before any handler
	// runs. All of them are checked, so one run reports every mismatch.
	var integrityErrors []string
	for _, pkg := range packages {
		if err := e.verifyArtifact(pkg); err != nil {
			integrityErrors = append(integrityErrors, err.Error())
			result.FailedPackages = append(result.FailedPackages, pkg.Name)
			packageResults[pkg.Name] = &models.ExecutionResult{
				Status:    models.PackageStatusFailed,
				Error:     err.Error(),
				Timestamp: time.Now(),
			}
		}
	}
	if len(integrityErrors) > 0 {
		result.IntegrityFailure = true
		return e.stop(InstallResultFile, result, packageResults, errors.New(strings.Join(integrityErrors, "; ")))
	}

	// Process each package in order
	dependencyStatus := make(map[string]string)
	stopped := false

	for _, pkg := range packages {
		// A run told to stop at the first failure records the packages it
		// never reached, so the result accounts for everything in the lock.
		if stopped {
			result.NotRunPackages = append(result.NotRunPackages, pkg.Name)
			dependencyStatus[pkg.Name] = models.PackageStatusNotRun
			packageResults[pkg.Name] = &models.ExecutionResult{
				Status:    models.PackageStatusNotRun,
				Timestamp: time.Now(),
			}
			continue
		}

		// Never install a package whose dependency did not install. A
		// dependency that only needs a restart did install.
		blockedBy := ""
		for _, dep := range pkg.Dependencies {
			status, seen := dependencyStatus[dep]
			if seen && status != models.PackageStatusSuccess && status != models.PackageStatusRestart {
				blockedBy = dep
				break
			}
		}
		if blockedBy != "" {
			e.logger.Warn("Package cannot be installed due to failed dependency", map[string]interface{}{
				"package":    pkg.Name,
				"dependency": blockedBy,
			})
			result.BlockedPackages = append(result.BlockedPackages, pkg.Name)
			dependencyStatus[pkg.Name] = models.PackageStatusBlocked
			packageResults[pkg.Name] = &models.ExecutionResult{
				Status:    models.PackageStatusBlocked,
				Error:     "dependency did not install: " + blockedBy,
				Timestamp: time.Now(),
			}
			continue
		}

		// Install the package
		execResult, err := e.installPackage(pkg)
		if err != nil && execResult == nil {
			execResult = &models.ExecutionResult{
				Status:    models.PackageStatusFailed,
				Error:     err.Error(),
				Timestamp: time.Now(),
			}
		}

		packageResults[pkg.Name] = execResult
		dependencyStatus[pkg.Name] = execResult.Status

		// Update overall result
		switch execResult.Status {
		case models.PackageStatusSuccess:
			result.SuccessfulPackages = append(result.SuccessfulPackages, pkg.Name)
		case models.PackageStatusRestart:
			result.RestartPackages = append(result.RestartPackages, pkg.Name)
		default:
			// Anything else is a failure, including a package whose installed
			// state does not validate: the run must not report success for it.
			// The run carries on by default, so it reports every failure at
			// once; it has still failed.
			result.FailedPackages = append(result.FailedPackages, pkg.Name)
			result.OverallSuccess = false
			result.PublicationEligible = false
			if e.config.StopOnFailure {
				stopped = true
			}
		}
	}

	// Check if overall execution was successful
	if len(result.FailedPackages) > 0 || len(result.BlockedPackages) > 0 || len(result.NotRunPackages) > 0 {
		result.OverallSuccess = false
		result.PublicationEligible = false
	}
	result.RestartRequired = result.OverallSuccess && len(result.RestartPackages) > 0

	return e.finish(InstallResultFile, result, packageResults)
}

// Verify checks installed state without installing anything: it runs every
// package's validations, in install order, and writes its own result file.
// The image build runs it after the restart an install asked for, and it is
// safe to run at any time.
//
// The lock is checked against its sidecar first. The staged files are not
// re-hashed: verify runs nothing from them, and they may be gone by then.
func (e *Executor) Verify() (*ExecutionResult, error) {
	e.startedAt = time.Now()
	result := newResult()
	packageResults := make(map[string]*models.ExecutionResult)

	if err := e.loadPinnedLock(result); err != nil {
		return e.stop(VerifyResultFile, result, packageResults, err)
	}
	lock := e.lock

	packages := make([]*models.LockPackage, len(lock.Packages))
	copy(packages, lock.Packages)
	sort.SliceStable(packages, func(i, j int) bool {
		return packages[i].InstallOrder < packages[j].InstallOrder
	})
	e.order = packages

	for _, pkg := range packages {
		startTime := time.Now()
		execResult := &models.ExecutionResult{Status: models.PackageStatusSuccess}
		e.runValidations(pkg, execResult)
		execResult.Duration = time.Since(startTime)
		execResult.Timestamp = time.Now()
		packageResults[pkg.Name] = execResult

		if execResult.Status == models.PackageStatusSuccess {
			result.SuccessfulPackages = append(result.SuccessfulPackages, pkg.Name)
		} else {
			result.FailedPackages = append(result.FailedPackages, pkg.Name)
			result.OverallSuccess = false
		}
	}

	return e.finish(VerifyResultFile, result, packageResults)
}

// InstallPackage installs a specific package by name
func (e *Executor) InstallPackage(packageName string) (*models.ExecutionResult, error) {
	// Find the package in the lock file
	if e.lock == nil {
		lock, err := models.LoadImageRecipeLock(e.config.LockPath)
		if err != nil {
			return nil, fmt.Errorf("failed to load lock file: %w", err)
		}
		e.lock = lock
	}

	var targetPackage *models.LockPackage
	for _, pkg := range e.lock.Packages {
		if pkg.Name == packageName {
			targetPackage = pkg
			break
		}
	}

	if targetPackage == nil {
		return nil, fmt.Errorf("package %s not found in lock file", packageName)
	}

	return e.installPackage(targetPackage)
}

// installPackage performs the actual installation of a single package
func (e *Executor) installPackage(pkg *models.LockPackage) (*models.ExecutionResult, error) {
	ctx := context.Background()

	// Create working directory for this package
	pkgEvidenceDir := filepath.Join(pathutil.ExpandWindowsEnv(e.config.EvidenceDir), pkg.Name)
	if err := os.MkdirAll(pkgEvidenceDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create package evidence directory: %w", err)
	}

	// Check the staged file against the lock, unless Run already has
	if !e.verified[pkg.Name] {
		if err := e.verifyArtifact(pkg); err != nil {
			return &models.ExecutionResult{
				Status:    models.PackageStatusFailed,
				Error:     err.Error(),
				Timestamp: time.Now(),
			}, err
		}
	}

	artifactPath, err := e.getArtifactPath(pkg)
	if err != nil {
		return &models.ExecutionResult{
			Status:    models.PackageStatusFailed,
			Error:     err.Error(),
			Timestamp: time.Now(),
		}, err
	}

	// Create handler
	handler, err := e.handlerFactory.CreateHandler(handlers.HandlerConfig{
		LockPackage:  pkg,
		ArtifactPath: artifactPath,
		Logger:       e.logger,
	})
	if err != nil {
		return &models.ExecutionResult{
			Status:    models.PackageStatusFailed,
			Error:     err.Error(),
			Timestamp: time.Now(),
		}, err
	}

	// Enforce the package's timeout here, once, for every handler. Each
	// handler starts its process from this context, so the deadline ends the
	// process; the handlers' own timeout contexts are created after the
	// process has started and are attached to nothing.
	timeout := pkg.Install.Timeout
	if timeout <= 0 {
		timeout = defaultInstallTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	// Execute the handler
	startTime := time.Now()
	execResult, err := handler.Execute(ctx)
	// What the installer printed stays on the machine, beside the result
	// file, and out of it.
	e.saveInstallerOutput(pkgEvidenceDir, pkg, execResult)
	if err != nil {
		failed := &models.ExecutionResult{
			Status:    models.PackageStatusFailed,
			Error:     err.Error(),
			Timestamp: time.Now(),
			Duration:  time.Since(startTime),
		}
		if ctx.Err() == context.DeadlineExceeded {
			failed.Status = models.PackageStatusTimeout
			failed.Timeout = true
			failed.Error = fmt.Sprintf("installation timed out after %v", timeout)
			return failed, fmt.Errorf("installation of %s timed out after %v", pkg.Name, timeout)
		}
		return failed, fmt.Errorf("handler execution failed: %w", err)
	}
	execResult.Ran = true

	// Check result. A restart code is looked for first: a lock that lists
	// 3010 as both a success and a restart code means "installed, restart
	// needed", and reading it as plain success would lose the restart.
	if e.isRestart(execResult.ExitCode, pkg.Install.RestartExitCodes) {
		execResult.Status = models.PackageStatusRestart
		execResult.RestartDetected = true
	} else if e.isSuccess(execResult.ExitCode, pkg.Install.SuccessExitCodes) {
		execResult.Status = models.PackageStatusSuccess
	} else {
		execResult.Status = models.PackageStatusFailed
	}

	execResult.Duration = time.Since(startTime)
	execResult.Timestamp = time.Now()
	if execResult.Status == models.PackageStatusFailed {
		execResult.Error = fmt.Sprintf("installer exit code %d is not a success or restart code", execResult.ExitCode)
	}

	// Validate the installed state. A package that needs a restart is not
	// validated here: verify does that once the machine has restarted.
	if execResult.Status == models.PackageStatusSuccess {
		e.runValidations(pkg, execResult)
	}

	// Handle restart behavior
	if execResult.Status == models.PackageStatusRestart {
		switch pkg.RestartBehavior {
		case models.RestartBehaviorBlock:
			e.logger.Warn("Package requires restart (block behavior)", map[string]interface{}{
				"package": pkg.Name,
			})
		case models.RestartBehaviorReport:
		default:
			e.logger.Info("Package requires restart", map[string]interface{}{
				"package": pkg.Name,
			})
		}
	}

	return execResult, nil
}

// runValidations runs every validation the lock declares for a package and
// attaches each one's evidence to the package result. All of them run, even
// after one fails, so the evidence covers everything that was asked for. Any
// failure, including a validator that cannot be created, marks the package
// validation_failed.
func (e *Executor) runValidations(pkg *models.LockPackage, execResult *models.ExecutionResult) {
	logger := e.logger.WithFields(logging.Fields{
		"package":         pkg.Name,
		"package_version": pkg.Version,
	})
	if e.config != nil && e.config.ExecutionID != "" {
		logger = logger.WithExecutionID(e.config.ExecutionID)
	}

	// "Installed correctly" means the declared validation passed. A package
	// that declares none has nothing to pass, so it cannot be reported as a
	// success: an installer's exit code alone is not evidence of what is on
	// the machine.
	if len(pkg.Validation) == 0 {
		missing := validators.FailedEvidence("none", errors.New("the package declares no validation"))
		missing.Package = pkg.Name
		missing.PackageVersion = pkg.Version
		validators.LogEvidence(logger, missing)
		execResult.Validations = append(execResult.Validations, missing)
		execResult.Status = models.PackageStatusValidationFailed
		return
	}

	for _, validatorSpec := range pkg.Validation {
		var result *models.ExecutionResult
		validator, err := validators.NewValidator(validatorSpec.Handler, validatorSpec.Parameters, logger)
		if err == nil {
			result, err = validator.Validate()
		}

		var evidence []models.ValidationEvidence
		if result != nil {
			evidence = result.Validations
			if err == nil && result.Status != models.PackageStatusSuccess {
				err = fmt.Errorf("validator reported status %s", result.Status)
			}
		}
		if len(evidence) == 0 && err != nil {
			// The validator never produced a record: write one, so the
			// validation is not simply absent from the evidence.
			failed := validators.FailedEvidence(validatorSpec.Handler, err)
			validators.LogEvidence(logger, failed)
			evidence = []models.ValidationEvidence{failed}
		}

		for i := range evidence {
			evidence[i].Package = pkg.Name
			evidence[i].PackageVersion = pkg.Version
		}
		execResult.Validations = append(execResult.Validations, evidence...)

		if err != nil {
			execResult.Status = models.PackageStatusValidationFailed
		}
	}
}

// isSuccess checks if the exit code indicates success
func (e *Executor) isSuccess(exitCode int, successCodes []int) bool {
	for _, code := range successCodes {
		if exitCode == code {
			return true
		}
	}
	return exitCode == 0
}

// isRestart checks if the exit code indicates a restart is required
func (e *Executor) isRestart(exitCode int, restartCodes []int) bool {
	for _, code := range restartCodes {
		if exitCode == code {
			return true
		}
	}
	return false
}
