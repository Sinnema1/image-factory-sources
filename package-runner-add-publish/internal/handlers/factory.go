// Package handlers contains the installation handlers for package-runner
//go:build (windows || linux || ignore || linux) && (windows || linux)
// +build windows linux ignore linux
// +build windows linux

package handlers

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"

	"package-runner/internal/logging"
	"package-runner/internal/models"
)

// HandlerContext provides context information to handlers
type HandlerContext struct {
	PackageName    string
	PackageVersion string
	Package        *models.LockPackage
	EvidenceDir    string
	Logger         *logging.Logger
}

// Handler is the interface all installation handlers must implement
type Handler interface {
	Execute(ctx context.Context) (*models.ExecutionResult, error)
	HandlerName() string
	HandlerType() string
	ValidateDependencies() error
	Cleanup() error
}

// HandlerConfig contains configuration for creating handlers
type HandlerConfig struct {
	LockPackage  *models.LockPackage
	ArtifactPath string
	Logger       *logging.Logger
}

// Factory creates handlers based on handler type
type Factory struct {
	logger *logging.Logger
}

// NewFactory creates a new handler factory
func NewFactory(logger *logging.Logger) *Factory {
	return &Factory{
		logger: logger,
	}
}

// CreateHandler creates a handler based on the configuration
func (f *Factory) CreateHandler(config HandlerConfig) (Handler, error) {
	return NewHandler(config)
}

// NewHandler creates an appropriate handler based on the configuration
func NewHandler(config HandlerConfig) (Handler, error) {
	if config.LockPackage == nil {
		return nil, fmt.Errorf("lock package is required")
	}

	handlerType := strings.ToLower(config.LockPackage.Install.Handler)

	switch handlerType {
	case "msi":
		// For MSI, the artifact should be the .msi file
		if !strings.HasSuffix(strings.ToLower(config.ArtifactPath), ".msi") {
			return nil, fmt.Errorf("MSI handler requires a .msi file, got: %s", config.ArtifactPath)
		}
		return NewMSIHandler(config.ArtifactPath, config.LockPackage.Install, config.Logger)

	case "exe":
		// For EXE, the artifact should be the .exe file
		if !strings.HasSuffix(strings.ToLower(config.ArtifactPath), ".exe") {
			return nil, fmt.Errorf("EXE handler requires a .exe file, got: %s", config.ArtifactPath)
		}
		return NewEXEHandler(config.ArtifactPath, config.LockPackage.Install, config.Logger)

	case "powershell":
		// For PowerShell, the artifact should be the .ps1 file
		if !strings.HasSuffix(strings.ToLower(config.ArtifactPath), ".ps1") {
			return nil, fmt.Errorf("PowerShell handler requires a .ps1 file, got: %s", config.ArtifactPath)
		}
		return NewPowerShellHandler(config.ArtifactPath, config.LockPackage.Install, config.Logger)

	case "psadt":
		// For PSADT, the artifact is typically Deploy-Application.exe or similar
		return NewPSADTHandler(config.ArtifactPath, config.LockPackage.Install, config.Logger)

	default:
		return nil, fmt.Errorf("unknown handler type: %s", handlerType)
	}
}

// GetHandlerTypes returns a list of all supported handler types
func GetHandlerTypes() []string {
	return []string{"msi", "exe", "powershell", "psadt"}
}

// ValidateArtifactPath validates that the artifact path is appropriate for the handler type
func ValidateArtifactPath(handlerType, artifactPath string) error {
	handlerType = strings.ToLower(handlerType)
	artifactPath = strings.ToLower(artifactPath)

	switch handlerType {
	case "msi":
		if !strings.HasSuffix(artifactPath, ".msi") {
			return fmt.Errorf("MSI handler requires .msi file extension")
		}
	case "exe":
		if !strings.HasSuffix(artifactPath, ".exe") {
			return fmt.Errorf("EXE handler requires .exe file extension")
		}
	case "powershell":
		if !strings.HasSuffix(artifactPath, ".ps1") {
			return fmt.Errorf("PowerShell handler requires .ps1 file extension")
		}
	case "psadt":
		// PSADT entry point is typically an executable
		if !strings.HasSuffix(artifactPath, ".exe") && !filepath.IsAbs(artifactPath) {
			return fmt.Errorf("PSADT handler requires an absolute path to entry point")
		}
	default:
		return fmt.Errorf("unknown handler type: %s", handlerType)
	}

	return nil
}
