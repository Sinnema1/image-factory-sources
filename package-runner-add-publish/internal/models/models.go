// Package models contains the core data models for package-runner
package models

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// Handler types
const (
	HandlerTypeMSI        = "msi"
	HandlerTypeEXE        = "exe"
	HandlerTypePowerShell = "powershell"
	HandlerTypePSADT      = "psadt"
)

// Validator types
const (
	ValidatorTypeFile     = "file"
	ValidatorTypeRegistry = "registry"
	ValidatorTypeService  = "service"
	ValidatorTypeCommand  = "command"
)

// Package status constants
const (
	PackageStatusPending          = "pending"
	PackageStatusResolved         = "resolved"
	PackageStatusSuccess          = "success"
	PackageStatusFailed           = "failed"
	PackageStatusBlocked          = "blocked_dependency"
	PackageStatusValidationFailed = "validation_failed"
	PackageStatusTimeout          = "timeout"
	PackageStatusRestart          = "restart_required"
)

// Failure policy constants
const (
	FailurePolicyFail     = "fail"
	FailurePolicyContinue = "continue"
)

// Restart behavior constants
const (
	RestartBehaviorReport = "report"
	RestartBehaviorBlock  = "block"
)

// TimeNow returns current time in RFC3339 format
type TimeNow func() string

// Default TimeNow implementation
func defaultTimeNow() string {
	return time.Now().UTC().Format(time.RFC3339)
}

// ImageRecipe represents the image recipe structure
type ImageRecipe struct {
	APIVersion string               `yaml:"apiVersion" json:"apiVersion"`
	Kind       string               `yaml:"kind" json:"kind"`
	Metadata   ImageRecipeMetadata  `yaml:"metadata" json:"metadata"`
	Target     Target               `yaml:"target" json:"target"`
	Defaults   ImageRecipeDefaults  `yaml:"defaults" json:"defaults"`
	Packages   []ImageRecipePackage `yaml:"packages" json:"packages"`
}

// ImageRecipeMetadata represents the metadata section of an image recipe
type ImageRecipeMetadata struct {
	Name                   string `yaml:"name" json:"name"`
	Version                string `yaml:"version" json:"version"`
	BaselineClassification string `yaml:"baselineClassification,omitempty" json:"baselineClassification,omitempty"`
}

// Target represents the target section of an image recipe
type Target struct {
	Platform     string `yaml:"platform" json:"platform"`
	Release      string `yaml:"release" json:"release"`
	Architecture string `yaml:"architecture" json:"architecture"`
	ImageType    string `yaml:"imageType" json:"imageType"`
}

// ImageRecipeDefaults represents the defaults section of an image recipe
type ImageRecipeDefaults struct {
	FailurePolicy string `yaml:"failurePolicy,omitempty" json:"failurePolicy,omitempty"`
}

// ImageRecipePackage represents a package in an image recipe
type ImageRecipePackage struct {
	Name          string   `yaml:"name" json:"name"`
	Version       string   `yaml:"version" json:"version"`
	InstallOrder  int      `yaml:"installOrder,omitempty" json:"installOrder,omitempty"`
	Dependencies  []string `yaml:"dependencies,omitempty" json:"dependencies,omitempty"`
	FailurePolicy string   `yaml:"failurePolicy,omitempty" json:"failurePolicy,omitempty"`
}

// PackageDefinition represents a package definition
type PackageDefinition struct {
	APIVersion      string          `yaml:"apiVersion" json:"apiVersion"`
	Kind            string          `yaml:"kind" json:"kind"`
	Metadata        PackageMetadata `yaml:"metadata" json:"metadata"`
	Artifact        *Artifact       `yaml:"artifact,omitempty" json:"artifact,omitempty"`
	Install         InstallConfig   `yaml:"install" json:"install"`
	Validation      []ValidatorSpec `yaml:"validation,omitempty" json:"validation,omitempty"`
	RestartBehavior string          `yaml:"restartBehavior,omitempty" json:"restartBehavior,omitempty"`
}

// PackageMetadata represents the metadata section of a package definition
type PackageMetadata struct {
	Name    string `yaml:"name" json:"name"`
	Version string `yaml:"version" json:"version"`
}

// Artifact represents the artifact section of a package definition
type Artifact struct {
	Repository string `yaml:"repository" json:"repository"`
	Path       string `yaml:"path" json:"path"`
	Filename   string `yaml:"filename" json:"filename"`
	SHA256     string `yaml:"sha256,omitempty" json:"sha256,omitempty"`
	SizeBytes  uint64 `yaml:"sizeBytes" json:"sizeBytes"`
}

// InstallConfig represents the install section of a package definition
type InstallConfig struct {
	Handler          string        `yaml:"handler" json:"handler"`
	Arguments        []string      `yaml:"arguments,omitempty" json:"arguments,omitempty"`
	Timeout          time.Duration `yaml:"timeout,omitempty" json:"timeout,omitempty"` // in duration format (e.g., 30m)
	SuccessExitCodes []int         `yaml:"successExitCodes" json:"successExitCodes"`
	RestartExitCodes []int         `yaml:"restartExitCodes,omitempty" json:"restartExitCodes,omitempty"`
	WorkingDirectory string        `yaml:"workingDirectory,omitempty" json:"workingDirectory,omitempty"`
}

// // ValidationConfig represents the list of Validators in the validation section of a package definition
// type ValidationConfig struct {
// 	Validators []ValidatorSpec `yaml:"validation,omitempty"`
// }

// ValidationSpec represents the validation section of a package definition
type ValidatorSpec struct {
	Handler    string                 `yaml:"handler" json:"handler"`
	Parameters map[string]interface{} `yaml:"parameters,omitempty" json:"parameters,omitempty"`
}

// ExecutionResult represents the result of a package execution
type ExecutionResult struct {
	Status          string        `yaml:"status" json:"status"`
	ExitCode        int           `yaml:"exitCode" json:"exitCode"`
	Stdout          string        `yaml:"stdout" json:"stdout"`
	Stderr          string        `yaml:"stderr" json:"stderr"`
	Duration        time.Duration `yaml:"duration" json:"duration"`
	Timestamp       time.Time     `yaml:"timestamp" json:"timestamp"`
	RestartDetected bool          `yaml:"restartDetected,omitempty" json:"restartDetected,omitempty"`
	Timeout         bool          `yaml:"timeout,omitempty" json:"timeout,omitempty"`
}

// ImageRecipeLock represents a locked image recipe
type ImageRecipeLock struct {
	APIVersion string                  `yaml:"apiVersion" json:"apiVersion"`
	Kind       string                  `yaml:"kind" json:"kind"`
	Metadata   ImageRecipeLockMetadata `yaml:"metadata" json:"metadata"`
	Target     LockTarget              `yaml:"target" json:"target"`
	Defaults   LockDefaults            `yaml:"defaults" json:"defaults"`
	Packages   []*LockPackage          `yaml:"packages" json:"packages"`
}

// ImageRecipeLockMetadata represents the metadata section of a lock file
type ImageRecipeLockMetadata struct {
	Name        string `yaml:"name" json:"name"`
	Version     string `yaml:"version" json:"version"`
	GeneratedAt string `yaml:"generatedAt" json:"generatedAt"`
	LockHash    string `yaml:"lockHash,omitempty" json:"lockHash,omitempty"`
}

// LockTarget represents the target section of a lock file
type LockTarget struct {
	Platform     string `yaml:"platform" json:"platform"`
	Release      string `yaml:"release" json:"release"`
	Architecture string `yaml:"architecture" json:"architecture"`
	ImageType    string `yaml:"imageType" json:"imageType"`
}

// LockDefaults represents the defaults section of a lock file
type LockDefaults struct {
	FailurePolicy string `yaml:"failurePolicy,omitempty" json:"failurePolicy,omitempty"`
}

// LockPackage represents a package in a lock file
type LockPackage struct {
	Name            string          `yaml:"name" json:"name"`
	Version         string          `yaml:"version" json:"version"`
	InstallOrder    int             `yaml:"installOrder,omitempty" json:"installOrder,omitempty"`
	Dependencies    []string        `yaml:"dependencies,omitempty" json:"dependencies,omitempty"`
	FailurePolicy   string          `yaml:"failurePolicy,omitempty" json:"failurePolicy,omitempty"`
	RestartBehavior string          `yaml:"restartBehavior,omitempty" json:"restartBehavior,omitempty"`
	ResolvedFrom    string          `yaml:"resolvedFrom,omitempty" json:"resolvedFrom,omitempty"`
	Install         InstallConfig   `yaml:"install" json:"install"`
	Validation      []ValidatorSpec `yaml:"validation,omitempty" json:"validation,omitempty"`
	Artifact        *Artifact       `yaml:"artifact,omitempty" json:"artifact,omitempty"`
}

// LoadImageRecipe loads an image recipe from a file
func LoadImageRecipe(path string) (*ImageRecipe, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read recipe file: %w", err)
	}

	var recipe ImageRecipe
	if err := yaml.Unmarshal(data, &recipe); err != nil {
		return nil, fmt.Errorf("failed to parse recipe YAML: %w", err)
	}

	// Validate basic structure
	if recipe.APIVersion == "" || recipe.Kind == "" || recipe.Metadata.Name == "" {
		return nil, fmt.Errorf("invalid recipe structure")
	}

	return &recipe, nil
}

// LoadPackageDefinition loads a package definition from a file
func LoadPackageDefinition(path string) (*PackageDefinition, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read package definition file: %w", err)
	}

	var packageDef PackageDefinition
	if err := yaml.Unmarshal(data, &packageDef); err != nil {

		return nil, fmt.Errorf("failed to parse package definition YAML: %w", err)
	}

	// Validate basic structure
	if packageDef.APIVersion == "" || packageDef.Kind == "" || packageDef.Metadata.Name == "" {
		return nil, fmt.Errorf("invalid package definition structure")
	}

	return &packageDef, nil
}

// LoadImageRecipeLock loads a lock file
func LoadImageRecipeLock(path string) (*ImageRecipeLock, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read lock file: %w", err)
	}

	var lock ImageRecipeLock
	if err := yaml.Unmarshal(data, &lock); err != nil {
		return nil, fmt.Errorf("failed to parse lock file YAML: %w", err)
	}

	// Validate basic structure
	if lock.APIVersion == "" || lock.Kind == "" || lock.Metadata.Name == "" {
		return nil, fmt.Errorf("invalid lock file structure")
	}

	return &lock, nil
}

// CalculateLockHash calculates a SHA256 hash of the lock file content
func CalculateLockHash(lock *ImageRecipeLock) (string, error) {
	// Create a copy of the lock without the hash field to avoid circular dependency
	lockCopy := *lock
	lockCopy.Metadata.LockHash = ""

	data, err := yaml.Marshal(lockCopy)
	if err != nil {
		return "", fmt.Errorf("failed to marshal lock for hashing: %w", err)
	}

	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:]), nil
}

// IsValidHandlerType checks if a handler type is valid
func IsValidHandlerType(handler string) bool {
	switch strings.ToLower(handler) {
	case HandlerTypeMSI, HandlerTypeEXE, HandlerTypePowerShell, HandlerTypePSADT:
		return true
	default:
		return false
	}
}

// IsValidValidatorType checks if a validator type is valid
func IsValidValidatorType(validator string) bool {
	switch strings.ToLower(validator) {
	case ValidatorTypeFile, ValidatorTypeRegistry, ValidatorTypeService, ValidatorTypeCommand:
		return true
	default:
		return false
	}
}

// GetValidHandlerTypes returns all valid handler types
func GetValidHandlerTypes() []string {
	return []string{
		HandlerTypeMSI,
		HandlerTypeEXE,
		HandlerTypePowerShell,
		HandlerTypePSADT,
	}
}

// GetValidValidatorTypes returns all valid validator types
func GetValidValidatorTypes() []string {
	return []string{
		ValidatorTypeFile,
		ValidatorTypeRegistry,
		ValidatorTypeService,
		ValidatorTypeCommand,
	}
}
