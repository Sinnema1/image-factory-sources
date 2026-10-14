// Package handlers contains the installation handlers for package-runner
//go:build windows || linux
// +build windows linux

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

// PowerShellHandler implements the PowerShell installation handler
type PowerShellHandler struct {
	scriptPath   string
	arguments    []string
	timeout      time.Duration
	successCodes []int
	restartCodes []int
	workDir      string
	logger       *logging.Logger
}

// NewPowerShellHandler creates a new PowerShell handler
func NewPowerShellHandler(scriptPath string, config models.InstallConfig, logger *logging.Logger) (*PowerShellHandler, error) {
	// Validate script path
	if !filepath.IsAbs(scriptPath) {
		var err error
		scriptPath, err = filepath.Abs(scriptPath)
		if err != nil {
			return nil, fmt.Errorf("failed to get absolute path: %w", err)
		}
	}

	// Validate script exists
	if _, err := os.Stat(scriptPath); os.IsNotExist(err) {
		return nil, fmt.Errorf("PowerShell script not found: %s", scriptPath)
	}

	// Default timeout
	timeout := time.Duration(config.Timeout)
	if timeout == 0 {
		timeout = time.Duration(15) * time.Minute
	}

	// Default success codes
	successCodes := config.SuccessExitCodes
	if len(successCodes) == 0 {
		successCodes = []int{0}
	}

	return &PowerShellHandler{
		scriptPath:   scriptPath,
		arguments:    config.Arguments,
		timeout:      timeout,
		successCodes: successCodes,
		restartCodes: config.RestartExitCodes,
		workDir:      config.WorkingDirectory,
	}, nil
}

// Execute runs the PowerShell installation
func (h *PowerShellHandler) Execute(ctx context.Context) (*models.ExecutionResult, error) {
	startTime := time.Now()

	// Build command: powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File script.ps1
	args := []string{
		"-NonInteractive",
		"-NoProfile",
		"-ExecutionPolicy", "Bypass",
		"-File", h.scriptPath,
	}
	args = append(args, h.arguments...)

	cmd := exec.CommandContext(ctx, "powershell.exe", args...)

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
		return nil, fmt.Errorf("failed to start PowerShell: %w", err)
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
			}, fmt.Errorf("PowerShell script timed out after %v", h.timeout)
		}

		// Handle exit error
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			return nil, fmt.Errorf("failed to execute PowerShell: %w", err)
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
func (h *PowerShellHandler) HandlerName() string {
	return "powershell"
}

// HandlerType returns the handler type
func (h *PowerShellHandler) HandlerType() string {
	return "powershell"
}

// ValidateDependencies validates handler dependencies
func (h *PowerShellHandler) ValidateDependencies() error {
	// Check if PowerShell exists
	if _, err := exec.LookPath("powershell.exe"); err != nil {
		return fmt.Errorf("powershell.exe not found in PATH")
	}
	return nil
}

// Cleanup performs any necessary cleanup
func (h *PowerShellHandler) Cleanup() error {
	return nil
}
