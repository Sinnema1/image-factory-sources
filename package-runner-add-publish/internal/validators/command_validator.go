// Package validators contains validation handlers for package-runner
package validators

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"time"

	"package-runner/internal/logging"
	"package-runner/internal/models"
)

// CommandValidator executes a validation command
type CommandValidator struct {
	BaseValidator
	params  map[string]interface{}
	timeout time.Duration
}

// NewCommandValidator creates a new CommandValidator
func NewCommandValidator(params map[string]interface{}) (*CommandValidator, error) {
	if params == nil {
		return nil, &InvalidValidatorError{message: "parameters are required for command validator"}
	}

	// Validate required parameters
	if _, ok := params["command"]; !ok {
		return nil, &InvalidValidatorError{message: "command parameter is required for command validator"}
	}

	// Set default timeout if not specified
	timeout := 5 * time.Minute // Default 5 minute timeout
	if t, ok := params["timeout"]; ok {
		if timeoutVal, err := toDuration(t); err == nil {
			timeout = timeoutVal
		}
	}

	return &CommandValidator{
		BaseValidator: BaseValidator{params: params},
		params:        params,
		timeout:       timeout,
	}, nil
}

// SetLogger sets the logger for the validator
func (v *CommandValidator) SetLogger(logger *logging.Logger) {
	v.BaseValidator.SetLogger(logger)
}

// Validate performs the command validation
func (v *CommandValidator) Validate() (*models.ExecutionResult, error) {
	command, ok := v.params["command"].(string)
	if !ok {
		return nil, errors.New("invalid command parameter")
	}

	// Get arguments if provided
	args, ok := v.params["arguments"]
	var cmdArgs []string
	if ok {
		if argsSlice, ok := args.([]interface{}); ok {
			cmdArgs = make([]string, len(argsSlice))
			for i, arg := range argsSlice {
				if argStr, ok := arg.(string); ok {
					cmdArgs[i] = argStr
				} else {
					return nil, fmt.Errorf("invalid argument at index %d", i)
				}
			}
		} else {
			return nil, errors.New("arguments must be a list")
		}
	}

	// Execute the command
	ctx, cancel := context.WithTimeout(context.Background(), v.timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, command, cmdArgs...)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	startTime := time.Now()
	err := cmd.Run()
	duration := time.Since(startTime)

	// Check for timeout
	if err != nil && ctx.Err() == context.DeadlineExceeded {
		return &models.ExecutionResult{
			Status:    models.PackageStatusTimeout,
			ExitCode:  -1,
			Stdout:    stdout.String(),
			Stderr:    stderr.String(),
			Duration:  duration,
			Timestamp: time.Now(),
			Timeout:   true,
		}, fmt.Errorf("command validation timed out after %v", v.timeout)
	}

	// Check exit code
	var exitCode int
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			return nil, fmt.Errorf("failed to execute command: %w", err)
		}
	} else {
		exitCode = 0
	}

	// Check if exit code indicates success
	if exitCode != 0 {
		return &models.ExecutionResult{
			Status:    models.PackageStatusValidationFailed,
			ExitCode:  exitCode,
			Stdout:    stdout.String(),
			Stderr:    stderr.String(),
			Duration:  duration,
			Timestamp: time.Now(),
		}, fmt.Errorf("command validation failed with exit code %d", exitCode)
	}

	return &models.ExecutionResult{
		Status:    models.PackageStatusSuccess,
		ExitCode:  exitCode,
		Stdout:    stdout.String(),
		Stderr:    stderr.String(),
		Duration:  duration,
		Timestamp: time.Now(),
	}, nil
}

// ValidatorType returns the validator type
func (v *CommandValidator) ValidatorType() string {
	return "command"
}

// toDuration converts a parameter to time.Duration
func toDuration(param interface{}) (time.Duration, error) {
	switch v := param.(type) {
	case time.Duration:
		return v, nil
	case string:
		return time.ParseDuration(v)
	default:
		return 0, fmt.Errorf("invalid duration type: %T", param)
	}
}
