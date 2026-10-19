// Package validators contains validation handlers for package-runner
package validators

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
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

// Validate performs the command validation.
//
// The command's output stays in the result's Stdout and Stderr and is not
// written to the evidence log entry: a validation command can print anything,
// including values that should not be copied into build logs.
func (v *CommandValidator) Validate() (*models.ExecutionResult, error) {
	command, ok := v.params["command"].(string)
	if !ok {
		b := newEvidence(v.ValidatorType(), fmt.Sprint(v.params["command"]))
		b.fail(errors.New("invalid command parameter"))
		return v.finish(b)
	}

	// Get arguments if provided
	var cmdArgs []string
	var argsErr error
	if args, ok := v.params["arguments"]; ok {
		if argsSlice, ok := args.([]interface{}); ok {
			cmdArgs = make([]string, len(argsSlice))
			for i, arg := range argsSlice {
				if argStr, ok := arg.(string); ok {
					cmdArgs[i] = argStr
				} else if argsErr == nil {
					argsErr = fmt.Errorf("invalid argument at index %d", i)
				}
			}
		} else {
			argsErr = errors.New("arguments must be a list")
		}
	}

	b := newEvidence(v.ValidatorType(), strings.TrimSpace(command+" "+strings.Join(cmdArgs, " ")))
	if argsErr != nil {
		b.fail(argsErr)
		return v.finish(b)
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

	timedOut := err != nil && ctx.Err() == context.DeadlineExceeded
	b.check("completed_within_timeout", true, !timedOut, !timedOut)
	b.observe("timeout", v.timeout.String())

	// Check exit code
	exitCode := 0
	var actualExitCode interface{}
	switch {
	case timedOut:
		exitCode = -1
	case err != nil:
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			exitCode = exitErr.ExitCode()
			actualExitCode = exitCode
		} else {
			exitCode = -1
			b.fail(fmt.Errorf("failed to execute command: %w", err))
		}
	default:
		actualExitCode = exitCode
	}
	b.check("exit_code", 0, actualExitCode, actualExitCode == 0)

	result, finishErr := v.finish(b)
	result.ExitCode = exitCode
	result.Stdout = stdout.String()
	result.Stderr = stderr.String()
	result.Duration = duration
	if timedOut {
		result.Status = models.PackageStatusTimeout
		result.Timeout = true
	}
	return result, finishErr
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
