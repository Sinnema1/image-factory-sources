// Package config contains configuration structs for CLI commands
package config

// ResolveConfig contains configuration for the resolve command
type ResolveConfig struct {
	RecipePath  string
	PackageRoot string
	OutputPath  string
	LogLevel    string
}

// ValidateConfig contains configuration for the validate command
type ValidateConfig struct {
	LockPath        string
	VerifyArtifacts bool
	LogLevel        string
	PackageRoot     string
}

// InstallConfig contains configuration for the install command
type InstallConfig struct {
	LockPath          string
	EvidenceDir       string
	ExecutionID       string
	LogLevel          string
	ContinueOnFailure bool
}

// InstallPackageConfig contains configuration for the install-package command
type InstallPackageConfig struct {
	LockPath    string
	PackageID   string
	EvidenceDir string
	LogLevel    string
}

// DetectConfig contains configuration for the detect command
type DetectConfig struct {
	PackageDefinition string
	LogLevel          string
}
