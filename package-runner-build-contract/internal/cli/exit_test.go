package cli

import (
	"errors"
	"fmt"
	"testing"
)

func TestExitCode(t *testing.T) {
	cases := []struct {
		err  error
		want int
	}{
		{nil, 0},
		{errors.New("lock path is required"), 1},
		{exitWith(ExitPackageFailed, errors.New("a package failed")), 10},
		{exitWith(ExitIntegrity, errors.New("lock unreadable")), 11},
		// The code survives being wrapped on the way up.
		{fmt.Errorf("install: %w", exitWith(ExitPackageFailed, errors.New("a package failed"))), 10},
	}
	for _, c := range cases {
		if got := ExitCode(c.err); got != c.want {
			t.Errorf("ExitCode(%v) = %d, want %d", c.err, got, c.want)
		}
	}
}
