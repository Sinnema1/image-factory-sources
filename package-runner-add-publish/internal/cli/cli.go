// Package cli provides the command-line interface for package-runner
package cli

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"
	"runtime"

	"package-runner/internal/config"
	"package-runner/internal/executor"
	"package-runner/internal/handlers"
	"package-runner/internal/logging"
	"package-runner/internal/models"
	"package-runner/internal/resolver"
	"package-runner/internal/validators"
)

// Build version information (set by main)
var (
	Version string = "unknown"
	Commit  string = "unknown"
	Date    string = "unknown"
)

// Run executes the CLI command based on the provided arguments
func Run(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("no command provided")
	}

	command := args[0]
	commandArgs := args[1:]

	var err error

	switch strings.ToLower(command) {
	case "version":
		err = cmdVersion()
	case "handlers":
		err = cmdHandlers()
	case "resolve":
		err = cmdResolve(commandArgs)
	case "validate":
		err = cmdValidate(commandArgs)
	case "install":
		err = cmdInstall(commandArgs)
	case "install-package":
		err = cmdInstallPackage(commandArgs)
	case "detect":
		err = cmdDetect(commandArgs)
	default:
		err = fmt.Errorf("unknown command: %s", command)
	}

	return err
}

// cmdVersion shows version information
func cmdVersion() error {
	fmt.Printf("package-runner version %s\n", Version)
	fmt.Printf("commit: %s\n", Commit)
	fmt.Printf("built at: %s\n", Date)
	return nil
}

// cmdHandlers shows supported handler types
func cmdHandlers() error {
	handlerTypes := handlers.GetHandlerTypes()
	fmt.Println("Supported handler types:")
	for _, handler := range handlerTypes {
		fmt.Printf("  - %s\n", handler)
	}
	return nil
}

// cmdResolve resolves package dependencies and creates a lock file
func cmdResolve(args []string) error {
	config := &config.ResolveConfig{}

	fs := flag.NewFlagSet("resolve", flag.ExitOnError)
	fs.StringVar(&config.RecipePath, "recipe", "", "Path to the recipe file (required)")
	fs.StringVar(&config.PackageRoot, "package-root", ".", "Path to the package definitions root")
	fs.StringVar(&config.OutputPath, "output", "", "Path to the output lock file (required)")
	fs.StringVar(&config.LogLevel, "log-level", "INFO", "Log level: DEBUG, INFO, WARN, ERROR")

	if err := fs.Parse(args); err != nil {
		return err
	}

	// Validate required parameters
	if config.RecipePath == "" {
		return fmt.Errorf("recipe path is required")
	}
	if config.OutputPath == "" {
		return fmt.Errorf("output path is required")
	}

	// Create logger
	logger := logging.NewDefaultLogger()
	if config.LogLevel != "" {
		logger.SetMinLevel(logging.LogLevel(config.LogLevel))
	}

	// Execute resolve
	_, err := resolver.Resolve(context.Background(), &resolver.ResolveOptions{
		RecipePath:  config.RecipePath,
		PackageRoot: config.PackageRoot,
		OutputPath:  config.OutputPath,
		Logger:      logger,
	})

	if err != nil {
		logger.Error("resolve failed", map[string]interface{}{"error": err.Error()})
		return err
	}

	logger.Info("resolve completed successfully", map[string]interface{}{
		"lockPath": config.OutputPath,
	})

	return nil
}

// cmdValidate validates a lock file
func cmdValidate(args []string) error {
	config := &config.ValidateConfig{}

	fs := flag.NewFlagSet("validate", flag.ExitOnError)
	fs.StringVar(&config.LockPath, "lock", "", "Path to the lock file (required)")
	fs.BoolVar(&config.VerifyArtifacts, "verify-artifacts", false, "Verify artifact existence and hashes")
	fs.StringVar(&config.LogLevel, "log-level", "INFO", "Log level: DEBUG, INFO, WARN, ERROR")

	if err := fs.Parse(args); err != nil {
		return err
	}

	// Validate required parameters
	if config.LockPath == "" {
		return fmt.Errorf("lock path is required")
	}

	// Create logger
	logger := logging.NewDefaultLogger()
	if config.LogLevel != "" {
		logger.SetMinLevel(logging.LogLevel(config.LogLevel))
	}

	// Execute validation
	validator := validators.NewLockValidator(config.LockPath, config.PackageRoot, config.VerifyArtifacts, logger)

	if err := validator.Validate(); err != nil {
		logger.Error("validation failed", map[string]interface{}{"error": err.Error()})
		return err
	}

	logger.Info("validation completed successfully")

	return nil
}

// cmdInstall executes installation from a lock file
func cmdInstall(args []string) error {
	config := &config.InstallConfig{}

	fs := flag.NewFlagSet("install", flag.ExitOnError)
	fs.StringVar(&config.LockPath, "lock", "", "Path to the lock file (required)")
	fs.StringVar(&config.EvidenceDir, "evidence-dir", "./evidence", "Directory to store evidence files")
	fs.StringVar(&config.ExecutionID, "execution-id", "", "Unique execution ID")
	fs.StringVar(&config.LogLevel, "log-level", "INFO", "Log level: DEBUG, INFO, WARN, ERROR")
	fs.BoolVar(&config.ContinueOnFailure, "continue-on-failure", false, "Continue execution on package failure (for debugging)")

	if err := fs.Parse(args); err != nil {
		return err
	}

	// Validate required parameters
	if config.LockPath == "" {
		return fmt.Errorf("lock path is required")
	}

	// Create logger
	logger := logging.NewDefaultLogger()
	if config.LogLevel != "" {
		logger.SetMinLevel(logging.LogLevel(config.LogLevel))
	}

	// Create evidence directory if it doesn't exist
	if err := os.MkdirAll(config.EvidenceDir, 0755); err != nil {
		return fmt.Errorf("failed to create evidence directory: %w", err)
	}

	// Execute installation
	executor := executor.NewExecutor(&executor.ExecutorConfig{
		LockPath:          config.LockPath,
		EvidenceDir:       config.EvidenceDir,
		ExecutionID:       config.ExecutionID,
		Logger:            logger,
		ContinueOnFailure: config.ContinueOnFailure,
	})

	if runtime.GOOS != "windows" {
		return fmt.Errorf("this CLI command can only be run on windows OS")

	}
	// Run the executor
	result, err := executor.Run()

	if err != nil {
		logger.Error("installation failed", map[string]interface{}{"error": err.Error()})
		return err
	}

	// Check overall result
	if !result.OverallSuccess {
		logger.Error("installation completed with failures", map[string]interface{}{
			"successCount": len(result.SuccessfulPackages),
			"failedCount":  len(result.FailedPackages),
			"blockedCount": len(result.BlockedPackages),
		})
		return fmt.Errorf("installation failed with %d package failures", len(result.FailedPackages))
	}

	logger.Info("installation completed successfully", map[string]interface{}{
		"successCount": len(result.SuccessfulPackages),
		"totalCount":   len(result.SuccessfulPackages) + len(result.FailedPackages) + len(result.BlockedPackages),
	})

	return nil
}

// cmdInstallPackage installs a specific package from a lock file
func cmdInstallPackage(args []string) error {
	config := &config.InstallPackageConfig{}

	fs := flag.NewFlagSet("install-package", flag.ExitOnError)
	fs.StringVar(&config.LockPath, "lock", "", "Path to the lock file (required)")
	fs.StringVar(&config.PackageID, "package-id", "", "Package ID to install (required)")
	fs.StringVar(&config.EvidenceDir, "evidence-dir", "./evidence", "Directory to store evidence files")
	fs.StringVar(&config.LogLevel, "log-level", "INFO", "Log level: DEBUG, INFO, WARN, ERROR")

	if err := fs.Parse(args); err != nil {
		return err
	}

	// Validate required parameters
	if config.LockPath == "" {
		return fmt.Errorf("lock path is required")
	}
	if config.PackageID == "" {
		return fmt.Errorf("package-id is required")
	}

	// Create logger
	logger := logging.NewDefaultLogger()
	if config.LogLevel != "" {
		logger.SetMinLevel(logging.LogLevel(config.LogLevel))
	}

	// Create evidence directory if it doesn't exist
	if err := os.MkdirAll(config.EvidenceDir, 0755); err != nil {
		return fmt.Errorf("failed to create evidence directory: %w", err)
	}

	// Execute single package installation
	executor := executor.NewExecutor(&executor.ExecutorConfig{
		LockPath:    config.LockPath,
		EvidenceDir: config.EvidenceDir,
		Logger:      logger,
	})

	// Run only the specified package
	result, err := executor.InstallPackage(config.PackageID)

	if err != nil {
		logger.Error("package installation failed", map[string]interface{}{
			"package": config.PackageID,
			"error":   err.Error(),
		})
		return err
	}

	if result.Status != models.PackageStatusSuccess {
		logger.Error("package installation failed", map[string]interface{}{
			"package": config.PackageID,
			"status":  result.Status,
		})
		return fmt.Errorf("package installation failed with status: %s", result.Status)
	}

	logger.Info("package installation completed successfully", map[string]interface{}{
		"package": config.PackageID,
	})

	return nil
}

// cmdDetect detects package information from definition
func cmdDetect(args []string) error {
	config := &config.DetectConfig{}

	fs := flag.NewFlagSet("detect", flag.ExitOnError)
	fs.StringVar(&config.PackageDefinition, "package-definition", "", "Path to the package definition file (required)")
	fs.StringVar(&config.LogLevel, "log-level", "INFO", "Log level: DEBUG, INFO, WARN, ERROR")

	if err := fs.Parse(args); err != nil {
		return err
	}

	// Validate required parameters
	if config.PackageDefinition == "" {
		return fmt.Errorf("package-definition is required")
	}

	// Create logger
	logger := logging.NewDefaultLogger()
	if config.LogLevel != "" {
		logger.SetMinLevel(logging.LogLevel(config.LogLevel))
	}

	// Load and display package definition
	packageDef, err := models.LoadPackageDefinition(config.PackageDefinition)
	if err != nil {
		logger.Error("failed to load package definition", map[string]interface{}{
			"path":  config.PackageDefinition,
			"error": err.Error(),
		})
		return err
	}

	fmt.Printf("Package Definition: %s\n", config.PackageDefinition)
	fmt.Printf("Name: %s\n", packageDef.Metadata.Name)
	fmt.Printf("Version: %s\n", packageDef.Metadata.Version)
	fmt.Printf("Handler: %s\n", packageDef.Install.Handler)

	if packageDef.Artifact != nil {
		fmt.Printf("Artifact: %s\n", packageDef.Artifact.Filename)
		if packageDef.Artifact.SHA256 != "" {
			fmt.Printf("SHA256: %s\n", packageDef.Artifact.SHA256)
		}
		fmt.Printf("Size: %d bytes\n", packageDef.Artifact.SizeBytes)
	}
	// TODO: check print statemetn
	if packageDef.Validation != nil {
		fmt.Printf("Validation: %s\n", packageDef.Validation)
	}

	return nil
}
