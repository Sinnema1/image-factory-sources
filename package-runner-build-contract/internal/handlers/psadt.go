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

// PSADTHandler implements the PSADT installation handler
type PSADTHandler struct {
	entryPoint   string
	arguments    []string
	timeout      time.Duration
	successCodes []int
	restartCodes []int
	workDir      string
	logger       *logging.Logger
}

func NewPSADTHandler(entryPoint string, config models.InstallConfig, logger *logging.Logger) (*PSADTHandler, error) {
	// Validate entry point
	if !filepath.IsAbs(entryPoint) {
		var err error
		entryPoint, err = filepath.Abs(entryPoint)
		if err != nil {
			return nil, fmt.Errorf("failed to get absolute path: %w", err)
		}
	}

	// Validate entry point exists
	if _, err := os.Stat(entryPoint); os.IsNotExist(err) {
		return nil, fmt.Errorf("PSADT entry point not found: %s", entryPoint)
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

	return &PSADTHandler{
		entryPoint:   entryPoint,
		arguments:    config.Arguments,
		timeout:      timeout,
		successCodes: successCodes,
		restartCodes: config.RestartExitCodes,
		workDir:      config.WorkingDirectory,
	}, nil
}

func (h *PSADTHandler) Execute(ctx context.Context) (*models.ExecutionResult, error) {
	startTime := time.Now()

	// PSADT typically uses Deploy-Application.exe or similar
	args := h.arguments

	cmd := exec.CommandContext(ctx, h.entryPoint, args...)
	if h.workDir != "" {
		cmd.Dir = h.workDir
	}

	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start PSADT entry point: %w", err)
	}

	ctx, cancel := context.WithTimeout(ctx, h.timeout)
	defer cancel()

	err := cmd.Wait()
	duration := time.Since(startTime)
	var exitCode int

	if err != nil {
		if ctx.Err() == context.DeadlineExceeded {
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
			}, fmt.Errorf("PSADT execution timed out after %v", h.timeout)
		}
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			return nil, fmt.Errorf("failed to execute PSADT: %w", err)
		}
	} else {
		exitCode = cmd.ProcessState.ExitCode()
	}

	result := &models.ExecutionResult{
		Status:    "success",
		ExitCode:  exitCode,
		Stdout:    stdout.String(),
		Stderr:    stderr.String(),
		Duration:  duration,
		Timestamp: time.Now(),
	}

	if !containsInt(h.successCodes, exitCode) {
		if containsInt(h.restartCodes, exitCode) {
			result.RestartDetected = true
		} else {
			result.Status = "failed"
		}
	}

	return result, nil
}

func (h *PSADTHandler) HandlerName() string {
	return "psadt"
}

func (h *PSADTHandler) HandlerType() string {
	return "psadt"
}

func (h *PSADTHandler) ValidateDependencies() error {
	if _, err := os.Stat(h.entryPoint); os.IsNotExist(err) {
		return fmt.Errorf("PSADT entry point not found: %s", h.entryPoint)
	}
	return nil
}

func (h *PSADTHandler) Cleanup() error {
	return nil
}
