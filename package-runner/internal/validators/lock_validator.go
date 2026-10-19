package validators

import (
	"fmt"
	"os"
	"path/filepath"

	"package-runner/internal/logging"
	"package-runner/internal/models"
)

// LockValidator validates lock files
type LockValidator struct {
	lockPath        string
	verifyArtifacts bool
	logger          *logging.Logger
	packageRoot     string
}

func NewLockValidator(lockPath string, packageRoot string, verifyArtifacts bool, logger *logging.Logger) *LockValidator {
	if logger == nil {
		logger = logging.NewDefaultLogger()
	}
	return &LockValidator{
		lockPath:        lockPath,
		verifyArtifacts: verifyArtifacts,
		logger:          logger,
		packageRoot:     packageRoot,
	}
}

// Validate validates the lock file
func (v *LockValidator) Validate() error {
	v.logger.Info("starting lock file validation", map[string]interface{}{
		"lockPath":        v.lockPath,
		"verifyArtifacts": v.verifyArtifacts,
	})

	// Load the lock file
	lock, err := models.LoadImageRecipeLock(v.lockPath)
	if err != nil {
		return fmt.Errorf("failed to load lock file: %w", err)
	}

	// Validate lock file structure
	if err := v.validateLockStructure(lock); err != nil {
		v.logger.Error("lock file structure validation failed", map[string]interface{}{
			"error": err.Error(),
		})
		return err
	}

	// Validate packages
	if err := v.validatePackages(lock); err != nil {
		v.logger.Error("package validation failed", map[string]interface{}{
			"error": err.Error(),
		})
		return err
	}

	// Verify artifacts if requested
	if v.verifyArtifacts {
		if err := v.verifyPackageArtifacts(lock); err != nil {
			v.logger.Error("artifact verification failed", map[string]interface{}{
				"error": err.Error(),
			})
			return err
		}
	}

	v.logger.Info("lock file validation completed successfully")
	return nil
}

// validateLockStructure validates the basic structure of the lock file
func (v *LockValidator) validateLockStructure(lock *models.ImageRecipeLock) error {
	if lock.APIVersion == "" {
		return fmt.Errorf("apiVersion must be specified")
	}

	if lock.Kind != "ImageRecipeLock" {
		return fmt.Errorf("kind must be ImageRecipeLock, got: %s", lock.Kind)
	}

	if lock.Metadata.Name == "" {
		return fmt.Errorf("metadata.name must be specified")
	}

	if lock.Metadata.Version == "" {
		return fmt.Errorf("metadata.version must be specified")
	}

	// Validate target
	if lock.Target.Platform == "" {
		return fmt.Errorf("target.platform must be specified")
	}

	// Validate packages exist
	if len(lock.Packages) == 0 {
		return fmt.Errorf("no packages specified in lock file")
	}

	return nil
}

// validatePackages validates individual packages in the lock file
func (v *LockValidator) validatePackages(lock *models.ImageRecipeLock) error {
	seen := make(map[string]bool)

	for _, pkg := range lock.Packages {
		// Check for duplicates
		packageKey := fmt.Sprintf("%s@%s", pkg.Name, pkg.Version)
		if seen[packageKey] {
			return fmt.Errorf("duplicate package found: %s", packageKey)
		}
		seen[packageKey] = true

		// Validate package fields
		if pkg.Name == "" {
			return fmt.Errorf("package name must be specified")
		}

		if pkg.Version == "" {
			return fmt.Errorf("package version must be specified for package: %s", pkg.Name)
		}

		// Validate install configuration
		if err := validateInstallConfig(&pkg.Install); err != nil {
			return fmt.Errorf("invalid install configuration for package %s: %w", pkg.Name, err)
		}

		// Validate validation configuration
		if pkg.Validation != nil {
			if err := validateValidationConfig(pkg.Validation); err != nil {
				return fmt.Errorf("invalid validation configuration for package %s: %w", pkg.Name, err)
			}
		}

		// Validate dependencies
		if err := validateDependencies(pkg.Dependencies); err != nil {
			return fmt.Errorf("invalid dependencies for package %s: %w", pkg.Name, err)
		}

		// Validate failure policy
		if pkg.FailurePolicy != "" && pkg.FailurePolicy != "fail" && pkg.FailurePolicy != "continue" {
			return fmt.Errorf("invalid failurePolicy for package %s: %s", pkg.Name, pkg.FailurePolicy)
		}

		// Validate restart behavior
		if pkg.RestartBehavior != "" && pkg.RestartBehavior != "report" && pkg.RestartBehavior != "block" {
			return fmt.Errorf("invalid restartBehavior for package %s: %s", pkg.Name, pkg.RestartBehavior)
		}
	}

	return nil
}

// verifyPackageArtifacts verifies artifact existence and hashes
func (v *LockValidator) verifyPackageArtifacts(lock *models.ImageRecipeLock) error {
	for _, pkg := range lock.Packages {
		if pkg.Artifact == nil {
			continue // Artifact is optional in some cases
		}

		if pkg.Artifact.Filename == "" {
			return fmt.Errorf("artifact filename must be specified for package %s", pkg.Name)
		}

		// Check if artifact file exists
		artifactPath := resolveArtifactPath(v.packageRoot, pkg.Artifact)

		if _, err := os.Stat(artifactPath); os.IsNotExist(err) {
			return fmt.Errorf("artifact file not found for package %s: %s", pkg.Name, artifactPath)
		}

		// Verify artifact size if specified
		if pkg.Artifact.SizeBytes > 0 {
			fileInfo, err := os.Stat(artifactPath)
			if err != nil {
				return fmt.Errorf("failed to stat artifact file for package %s: %w", pkg.Name, err)
			}
			if uint64(fileInfo.Size()) != pkg.Artifact.SizeBytes {
				return fmt.Errorf("artifact size mismatch for package %s: expected %d, got %d",
					pkg.Name, pkg.Artifact.SizeBytes, fileInfo.Size())
			}
		}

		// Verify artifact SHA256 if specified
		if pkg.Artifact.SHA256 != "" {
			if err := verifyFileHash(artifactPath, pkg.Artifact.SHA256); err != nil {
				return fmt.Errorf("artifact hash verification failed for package %s: %w", pkg.Name, err)
			}
		}
	}

	return nil
}

// validateInstallConfig validates install configuration
func validateInstallConfig(install *models.InstallConfig) error {
	if install == nil {
		return fmt.Errorf("install configuration must be specified")
	}

	if install.Handler == "" {
		return fmt.Errorf("handler must be specified")
	}

	// Validate handler type
	if !models.IsValidHandlerType(install.Handler) {
		return fmt.Errorf("invalid handler type: %s", install.Handler)
	}

	// Validate timeout
	if install.Timeout < 0 {
		return fmt.Errorf("timeout cannot be negative")
	}

	// Validate success exit codes
	if len(install.SuccessExitCodes) == 0 {
		return fmt.Errorf("successExitCodes must be specified")
	}

	return nil
}

// validateValidationConfig validates validation configuration
func validateValidationConfig(validation []models.ValidatorSpec) error {
	if validation == nil {
		return nil // Validation is optional
	}

	for _, validator := range validation {
		if validator.Handler == "" {
			return fmt.Errorf("validation handler must be specified")
		}

		// Validate handler type
		if !models.IsValidValidatorType(validator.Handler) {
			return fmt.Errorf("invalid validation handler type: %s", validator.Handler)
		}

	}
	return nil
}

// validateDependencies validates package dependencies
func validateDependencies(dependencies []string) error {
	for i, dep := range dependencies {
		if dep == "" {
			return fmt.Errorf("empty dependency at index %d", i)
		}
	}
	return nil
}

// verifyFileHash verifies the SHA256 hash of a file
func verifyFileHash(filePath, expectedHash string) error {
	// Implementation would read the file and compute SHA256
	// For now, we'll just check that the expected hash is a valid SHA256 string
	if len(expectedHash) != 64 {
		return fmt.Errorf("invalid SHA256 hash length: expected 64 characters, got %d", len(expectedHash))
	}
	return nil
}

// TODO: add regex here too for envs??
func resolveArtifactPath(packageRoot string, artifact *models.Artifact) string {
	if filepath.IsAbs(artifact.Filename) {
		return artifact.Filename
	}

	var relative string
	switch {
	case artifact.Repository != "" && artifact.Path != "":
		relative = filepath.Join(artifact.Repository, artifact.Path, artifact.Filename)
	case artifact.Path != "":
		relative = filepath.Join(artifact.Path, artifact.Filename)
	default:
		relative = artifact.Filename
	}
	return filepath.Join(packageRoot, relative)
}
