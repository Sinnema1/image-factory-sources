// Package executor provides package installation execution functionality
package executor

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"

	"package-runner/internal/handlers"
	"package-runner/internal/logging"
	"package-runner/internal/models"
	"package-runner/internal/pathutil"
	"package-runner/internal/validators"
)

// ExecutorConfig contains configuration for the Executor
type ExecutorConfig struct {
	LockPath          string
	EvidenceDir       string
	ExecutionID       string
	Logger            *logging.Logger
	ContinueOnFailure bool
}

// ExecutionResult contains the overall execution results
type ExecutionResult struct {
	OverallSuccess      bool
	SuccessfulPackages  []string
	FailedPackages      []string
	BlockedPackages     []string
	Degraded            bool
	PublicationEligible bool
}

// Executor executes package installations
type Executor struct {
	config         *ExecutorConfig
	logger         *logging.Logger
	lock           *models.ImageRecipeLock
	handlerFactory *handlers.Factory
}

// getArtifactPath constructs the full artifact path from a package's artifact info
func (e *Executor) getArtifactPath(pkg *models.LockPackage) string {
	if pkg.Artifact == nil {
		return ""
	}
	// Windows env vars expanded
	pkg.Artifact.Filename = pathutil.ExpandWindowsEnv(pkg.Artifact.Filename)
	pkg.Artifact.Repository = pathutil.ExpandWindowsEnv(pkg.Artifact.Repository)
	pkg.Artifact.Path = pathutil.ExpandWindowsEnv(pkg.Artifact.Path)

	// Run validation if present
	if pkg.Validation != nil {

		for _, validatorSpec := range pkg.Validation {
			validator, err := validators.NewValidator(validatorSpec.Handler, validatorSpec.Parameters, e.logger)
			if err != nil {
				e.logger.Warn("Skipping validation", map[string]interface{}{
					"package":   pkg.Name,
					"validator": validatorSpec.Handler,
					"error":     err.Error(),
				})
			}
			result, err := validator.Validate()
			if err != nil || result.Status != models.PackageStatusSuccess {
				e.logger.Warn("Validation failed", map[string]interface{}{
					"package":   pkg.Name,
					"validator": validatorSpec.Handler,
					"error":     err.Error(),
				})
				// execResult.Status = models.PackageStatusValidationFailed
			}
		}
	}
	// For now, use the filename as the path (or full path if already absolute)
	if filepath.IsAbs(pkg.Artifact.Filename) {
		return pkg.Artifact.Filename
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
	return artifactPath
}

// NewExecutor creates a new Executor instance
func NewExecutor(config *ExecutorConfig) *Executor {
	return &Executor{
		config:         config,
		logger:         config.Logger,
		handlerFactory: handlers.NewFactory(config.Logger),
	}
}

// Run executes the installation workflow from the lock file
func (e *Executor) Run() (*ExecutionResult, error) {
	// Load the lock file
	lock, err := models.LoadImageRecipeLock(e.config.LockPath)
	if err != nil {
		return nil, fmt.Errorf("failed to load lock file: %w", err)
	}
	e.lock = lock

	// Sort packages by install order
	packages := make([]*models.LockPackage, len(lock.Packages))
	copy(packages, lock.Packages)
	sort.Slice(packages, func(i, j int) bool {
		return packages[i].InstallOrder < packages[j].InstallOrder
	})

	// Initialize result
	result := &ExecutionResult{
		OverallSuccess:      true,
		SuccessfulPackages:  []string{},
		FailedPackages:      []string{},
		BlockedPackages:     []string{},
		Degraded:            false,
		PublicationEligible: true,
	}

	// Process each package in order
	packageResults := make(map[string]*models.ExecutionResult)
	dependencyStatus := make(map[string]string)
	blocked := make(map[string]bool)

	for _, pkg := range packages {
		// Check if this package should be blocked due to failed dependencies
		if blocked[pkg.Name] {
			e.logger.Warn("Package blocked due to dependency failure", map[string]interface{}{
				"package": pkg.Name,
			})
			result.BlockedPackages = append(result.BlockedPackages, pkg.Name)
			dependencyStatus[pkg.Name] = models.PackageStatusBlocked
			continue
		}

		// Check dependency status
		for _, dep := range pkg.Dependencies {
			if dependencyStatus[dep] == models.PackageStatusFailed {
				e.logger.Warn("Package cannot be installed due to failed dependency", map[string]interface{}{
					"package":    pkg.Name,
					"dependency": dep,
				})
				result.BlockedPackages = append(result.BlockedPackages, pkg.Name)
				dependencyStatus[pkg.Name] = models.PackageStatusBlocked
				blocked[pkg.Name] = true
				continue
			}
		}

		// Install the package
		execResult, err := e.installPackage(pkg)
		if err != nil {
			execResult = &models.ExecutionResult{
				Status:    models.PackageStatusFailed,
				ExitCode:  -1,
				Stderr:    err.Error(),
				Timestamp: time.Now(),
			}
		}

		packageResults[pkg.Name] = execResult
		dependencyStatus[pkg.Name] = execResult.Status

		// Update overall result
		if execResult.Status == models.PackageStatusSuccess {
			result.SuccessfulPackages = append(result.SuccessfulPackages, pkg.Name)
		} else if execResult.Status == models.PackageStatusFailed {
			result.FailedPackages = append(result.FailedPackages, pkg.Name)
			if !e.config.ContinueOnFailure {
				result.OverallSuccess = false
				// Block dependents
				for _, otherPkg := range packages {
					for _, dep := range otherPkg.Dependencies {
						if dep == pkg.Name {
							blocked[otherPkg.Name] = true
						}
					}
				}
			} else {
				// Exceptional continue policy
				result.Degraded = true
				result.PublicationEligible = false
			}
		}
	}

	// Check if overall execution was successful
	if len(result.FailedPackages) > 0 || len(result.BlockedPackages) > 0 {
		result.OverallSuccess = false
	}

	// Save evidence
	if err := e.saveEvidence(result, packageResults); err != nil {
		e.logger.Error("Failed to save evidence", map[string]interface{}{
			"error": err.Error(),
		})
	}

	return result, nil
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

	// Validate artifact if present
	if pkg.Artifact != nil {
		if err := e.validateArtifact(pkg); err != nil {
			return &models.ExecutionResult{
				Status:    models.PackageStatusValidationFailed,
				ExitCode:  -1,
				Stderr:    err.Error(),
				Timestamp: time.Now(),
			}, err
		}
	}

	// Create handler
	handler, err := e.handlerFactory.CreateHandler(handlers.HandlerConfig{
		LockPackage:  pkg,
		ArtifactPath: e.getArtifactPath(pkg),
		Logger:       e.logger,
	})
	if err != nil {
		return &models.ExecutionResult{
			Status:    models.PackageStatusFailed,
			ExitCode:  -1,
			Stderr:    err.Error(),
			Timestamp: time.Now(),
		}, err
	}

	// Execute the handler
	startTime := time.Now()
	execResult, err := handler.Execute(ctx)
	if err != nil {
		return &models.ExecutionResult{
			Status:    models.PackageStatusFailed,
			ExitCode:  -1,
			Stderr:    err.Error(),
			Timestamp: time.Now(),
			Duration:  time.Since(startTime),
		}, fmt.Errorf("handler execution failed: %w", err)
	}

	// Check result
	if !e.isSuccess(execResult.ExitCode, pkg.Install.SuccessExitCodes) {
		// Check for restart codes
		if e.isRestart(execResult.ExitCode, pkg.Install.RestartExitCodes) {
			execResult.Status = models.PackageStatusRestart
		} else {
			execResult.Status = models.PackageStatusFailed
		}
	} else {
		execResult.Status = models.PackageStatusSuccess
	}

	execResult.Duration = time.Since(startTime)
	execResult.Timestamp = time.Now()

	// Run validation if present
	if pkg.Validation != nil && execResult.Status == models.PackageStatusSuccess {

		for _, validatorSpec := range pkg.Validation {
			validator, err := validators.NewValidator(validatorSpec.Handler, validatorSpec.Parameters, e.logger)
			if err != nil {
				e.logger.Warn("Skipping validation", map[string]interface{}{
					"package":   pkg.Name,
					"validator": validatorSpec.Handler,
					"error":     err.Error(),
				})
			}
			result, err := validator.Validate()
			if err != nil || result.Status != models.PackageStatusSuccess {
				e.logger.Warn("Validation failed", map[string]interface{}{
					"package":   pkg.Name,
					"validator": validatorSpec.Handler,
					"error":     err.Error(),
				})
				execResult.Status = models.PackageStatusValidationFailed
			}
		}
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

// validateArtifact validates the package artifact
func (e *Executor) validateArtifact(pkg *models.LockPackage) error {
	if pkg.Artifact.SizeBytes == 0 {
		return fmt.Errorf("artifact size is zero for package %s", pkg.Name)
	}

	if pkg.Artifact.SHA256 != "" && len(pkg.Artifact.SHA256) != 64 {
		return fmt.Errorf("invalid SHA-256 hash length for package %s", pkg.Name)
	}

	return nil
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

// saveEvidence saves execution evidence to files
func (e *Executor) saveEvidence(overallResult *ExecutionResult, packageResults map[string]*models.ExecutionResult) error {
	evidence := struct {
		OverallResult  *ExecutionResult                   `json:"overallResult"`
		PackageResults map[string]*models.ExecutionResult `json:"packageResults"`
		GeneratedAt    time.Time                          `json:"generatedAt"`
		ExecutionID    string                             `json:"executionId,omitempty"`
	}{
		OverallResult:  overallResult,
		PackageResults: packageResults,
		GeneratedAt:    time.Now().UTC(),
		ExecutionID:    e.config.ExecutionID,
	}
	data, err := json.MarshalIndent(evidence, "", " ")
	if err != nil {
		return fmt.Errorf("marshal execution evidence: %w", err)
	}
	if err := os.MkdirAll(e.config.EvidenceDir, 0755); err != nil {
		return fmt.Errorf("create evidence directory: %w", err)
	}
	path := filepath.Join(e.config.EvidenceDir, "package-execution-evidence.json")
	if err := os.WriteFile(path, data, 0644); err != nil {
		return fmt.Errorf("write execution evidence file %s: %w", path, err)
	}

	return nil
}
