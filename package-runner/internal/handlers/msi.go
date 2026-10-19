// Package handlers contains the installation handlers for package-runner

package handlers

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"package-runner/internal/logging"
	"package-runner/internal/models"
)

// MSIHandler implements the MSI installation handler
type MSIHandler struct {
	artifactPath string
	arguments    []string
	timeout      time.Duration
	successCodes []int
	restartCodes []int
	workDir      string
	logger       *logging.Logger
	redactArgs   []string
}

// NewMSIHandler creates a new MSI handler
func NewMSIHandler(artifactPath string, config models.InstallConfig, logger *logging.Logger) (*MSIHandler, error) {
	// Validate artifact path
	if !filepath.IsAbs(artifactPath) {
		var err error
		artifactPath, err = filepath.Abs(artifactPath)
		if err != nil {
			return nil, fmt.Errorf("failed to get absolute path: %w", err)
		}
	}

	// Validate artifact exists
	if _, err := os.Stat(artifactPath); os.IsNotExist(err) {
		return nil, fmt.Errorf("MSI artifact not found: %s", artifactPath)
	}

	// Default timeout
	timeout := config.Timeout
	if timeout == 0 {
		timeout = 30 * time.Minute
	}

	// Default success codes
	successCodes := config.SuccessExitCodes
	if len(successCodes) == 0 {
		successCodes = []int{0, 3010} // 0 = success, 3010 = success with restart
	}

	// Redact sensitive arguments
	var redactArgs []string
	for _, arg := range config.Arguments {
		if isSensitiveArg(arg) {
			redactArgs = append(redactArgs, arg)
		}
	}

	return &MSIHandler{
		artifactPath: artifactPath,
		arguments:    config.Arguments,
		timeout:      timeout,
		successCodes: successCodes,
		restartCodes: config.RestartExitCodes,
		workDir:      config.WorkingDirectory,
		logger:       logger,
		redactArgs:   redactArgs,
	}, nil
}

// Execute runs the MSI installation
func (h *MSIHandler) Execute(ctx context.Context) (*models.ExecutionResult, error) {
	h.logger.Info("Starting MSI installation", map[string]interface{}{"artifact": h.artifactPath})

	startTime := time.Now()

	// Build command
	args := []string{"/i", h.artifactPath}
	args = append(args, h.arguments...)

	// Redact sensitive args in logs
	displayArgs := redactArguments(args, h.redactArgs)
	h.logger.Debug("MSI command",
		map[string]interface{}{"executable": "msiexec.exe", "arguments": displayArgs})

	cmd := exec.CommandContext(ctx, "msiexec.exe", args...)

	// Set working directory
	if h.workDir != "" {
		cmd.Dir = h.workDir
	}

	// Capture output
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	// Start process
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start msiexec: %w", err)
	}

	// Wait with timeout
	done := make(chan error, 1)
	go func() {
		done <- cmd.Wait()
	}()

	select {
	case <-ctx.Done():
		// Context cancelled, kill process
		if err := cmd.Process.Kill(); err != nil {
			h.logger.Warn("Failed to kill msiexec process", map[string]interface{}{"error": err})
		}
		<-done // Wait for process to finish
		return &models.ExecutionResult{
			Status:   "failed",
			ExitCode: -1,
			Stdout:   stdout.String(),
			Stderr:   stderr.String(),
			Duration: time.Since(startTime),
			Timeout:  true,
		}, fmt.Errorf("installation timed out after %v", h.timeout)

	case err := <-done:
		if err != nil {
			// Process finished with error
			var exitErr *exec.ExitError
			if errors.As(err, &exitErr) {
				return h.createResult(cmd.ProcessState.ExitCode(), stdout.String(), stderr.String(), startTime)
			}
			return nil, fmt.Errorf("msiexec failed: %w", err)
		}

		// Process finished successfully
		return h.createResult(cmd.ProcessState.ExitCode(), stdout.String(), stderr.String(), startTime)
	}
}

// createResult creates an ExecutionResult from the exit code
func (h *MSIHandler) createResult(exitCode int, stdout, stderr string, startTime time.Time) (*models.ExecutionResult, error) {
	duration := time.Since(startTime)

	result := &models.ExecutionResult{
		Status:    "success",
		ExitCode:  exitCode,
		Stdout:    stdout,
		Stderr:    stderr,
		Duration:  duration,
		Timestamp: time.Now(),
	}

	// Check if exit code indicates success
	if !containsInt(h.successCodes, exitCode) {
		// Check if it's a restart code
		if containsInt(h.restartCodes, exitCode) {
			result.RestartDetected = true
			result.Status = "success"
		} else {
			result.Status = "failed"
		}
	}

	return result, nil
}

// HandlerName returns the handler name
func (h *MSIHandler) HandlerName() string {
	return "msi"
}

// HandlerType returns the handler type
func (h *MSIHandler) HandlerType() string {
	return "msi"
}

// ValidateDependencies validates handler dependencies (msiexec.exe must exist)
func (h *MSIHandler) ValidateDependencies() error {
	// Check if msiexec.exe exists
	msiexecPath := filepath.Join(os.Getenv("WINDIR"), "System32", "msiexec.exe")
	if _, err := os.Stat(msiexecPath); os.IsNotExist(err) {
		return fmt.Errorf("msiexec.exe not found at %s", msiexecPath)
	}
	return nil
}

// isSensitiveArg checks if an argument should be redacted
func isSensitiveArg(arg string) bool {
	sensitivePrefixes := []string{
		"/qn", "-qn", "--quiet", "--silent",
		"/password", "-password", "--password",
		"/secret", "-secret", "--secret",
		"PASSWORD=", "SECRET=", "TOKEN=",
	}

	lowerArg := strings.ToLower(arg)
	for _, prefix := range sensitivePrefixes {
		if strings.HasPrefix(lowerArg, prefix) || strings.Contains(lowerArg, prefix) {
			return true
		}
	}
	return false
}

// redactArguments redacts sensitive arguments
func redactArguments(args []string, sensitiveArgs []string) []string {
	sensitiveMap := make(map[string]bool)
	for _, arg := range sensitiveArgs {
		sensitiveMap[arg] = true
	}

	result := make([]string, len(args))
	for i, arg := range args {
		if sensitiveMap[arg] || isSensitiveArg(arg) {
			result[i] = "[REDACTED]"
		} else {
			result[i] = arg
		}
	}
	return result
}

// Cleanup performs any necessary cleanup
func (h *MSIHandler) Cleanup() error {
	// Nothing to clean up for MSI handler
	return nil
}
