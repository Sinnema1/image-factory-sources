// Package handlers contains the installation handlers for package-runner

package handlers

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"package-runner/internal/logging"
	"package-runner/internal/models"
)

// EXEHandler implements the EXE installation handler
type EXEHandler struct {
	artifactPath string
	arguments    []string
	timeout      time.Duration
	successCodes []int
	restartCodes []int
	workDir      string
	logger       *logging.Logger
}

// NewEXEHandler creates a new EXE handler
func NewEXEHandler(artifactPath string, config models.InstallConfig, logger *logging.Logger) (*EXEHandler, error) {
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
		return nil, fmt.Errorf("EXE artifact not found: %s", artifactPath)
	}

	// Default timeout
	timeout := config.Timeout
	if timeout == 0 {
		timeout = 30 * time.Minute
	}

	// Default success codes
	successCodes := config.SuccessExitCodes
	if len(successCodes) == 0 {
		successCodes = []int{0}
	}

	return &EXEHandler{
		artifactPath: artifactPath,
		arguments:    config.Arguments,
		timeout:      timeout,
		successCodes: successCodes,
		restartCodes: config.RestartExitCodes,
		workDir:      config.WorkingDirectory,
		logger:       logger,
	}, nil
}

// Execute runs the EXE installation
func (h *EXEHandler) Execute(ctx context.Context) (*models.ExecutionResult, error) {
	startTime := time.Now()

	// Build command - executable is the artifact itself
	cmd := exec.CommandContext(ctx, h.artifactPath, h.arguments...)

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
		return nil, fmt.Errorf("failed to start executable: %w", err)
	}

	// Create a new context with timeout
	ctx, cancel := context.WithTimeout(ctx, h.timeout)
	defer cancel()

	// Wait for process or timeout
	err := cmd.Wait()

	duration := time.Since(startTime)
	var exitCode int

	if err != nil {
		// Check for timeout
		if ctx.Err() == context.DeadlineExceeded {
			// Kill the process if still running
			if cmd.Process != nil {
				cmd.Process.Kill()
			}
			return &models.ExecutionResult{
				Status:   "failed",
				ExitCode: -1,
				Stdout:   stdout.String(),
				Stderr:   stderr.String(),
				Duration: duration,
				Timeout:  true,
			}, fmt.Errorf("installation timed out after %v", h.timeout)
		}

		// Handle exit error
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			return nil, fmt.Errorf("failed to execute: %w", err)
		}
	} else {
		exitCode = cmd.ProcessState.ExitCode()
	}

	// Create result
	result := &models.ExecutionResult{
		Status:    "success",
		ExitCode:  exitCode,
		Stdout:    stdout.String(),
		Stderr:    stderr.String(),
		Duration:  duration,
		Timestamp: time.Now(),
	}

	// Check exit code
	if !containsInt(h.successCodes, exitCode) {
		if containsInt(h.restartCodes, exitCode) {
			result.RestartDetected = true
		} else {
			result.Status = "failed"
		}
	}

	return result, nil
}

// HandlerName returns the handler name
func (h *EXEHandler) HandlerName() string {
	return "exe"
}

// HandlerType returns the handler type
func (h *EXEHandler) HandlerType() string {
	return "exe"
}

// ValidateDependencies validates handler dependencies
func (h *EXEHandler) ValidateDependencies() error {
	// The executable is the artifact itself, so we just need to verify it exists
	if _, err := os.Stat(h.artifactPath); os.IsNotExist(err) {
		return fmt.Errorf("artifact not found: %s", h.artifactPath)
	}
	return nil
}

// Cleanup performs any necessary cleanup
func (h *EXEHandler) Cleanup() error {
	return nil
}
