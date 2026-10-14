package cli

import (
	"errors"

	"package-runner/internal/executor"
)

// Exit codes of the install and verify commands. The image build tells these
// apart: it fetches the result file after any of them, then fails the build on
// everything but success and restart-required. Any other failure, such as a
// missing required flag, exits 1.
const (
	ExitSuccess         = executor.ExitSuccess
	ExitPackageFailed   = executor.ExitPackageFailed
	ExitIntegrity       = executor.ExitIntegrity
	ExitNotElevated     = executor.ExitNotElevated
	ExitRestartRequired = executor.ExitRestartRequired
)

// ExitError is an error that carries the exit code the process should end
// with.
type ExitError struct {
	Code int
	Err  error
}

func (e *ExitError) Error() string { return e.Err.Error() }

func (e *ExitError) Unwrap() error { return e.Err }

// exitWith wraps err with an exit code.
func exitWith(code int, err error) error {
	return &ExitError{Code: code, Err: err}
}

// ExitCode returns the exit code for an error returned by Run: 0 for nil, the
// carried code for an ExitError, and 1 for anything else.
func ExitCode(err error) int {
	if err == nil {
		return ExitSuccess
	}
	var exitErr *ExitError
	if errors.As(err, &exitErr) {
		return exitErr.Code
	}
	return 1
}
