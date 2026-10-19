// Package integrity holds the hash checks that tie what runs to what was
// pinned: a lock file against its sidecar, and a staged file against the lock.
package integrity

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// SidecarSuffix is appended to a lock file's path to name its sidecar.
const SidecarSuffix = ".sha256"

// ErrNoSidecar is returned by VerifySidecar when the file has no sidecar. A
// caller may treat that as "nothing to check" rather than as a failure; a
// sidecar that exists and does not match is always a failure.
var ErrNoSidecar = errors.New("no sidecar")

var sha256Pattern = regexp.MustCompile(`^[0-9a-fA-F]{64}$`)

// IsSHA256 reports whether value is 64 hexadecimal characters.
func IsSHA256(value string) bool {
	return sha256Pattern.MatchString(value)
}

// FileSHA256 returns the SHA-256 of a file as lower-case hex, and its size.
func FileSHA256(path string) (string, int64, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer file.Close()

	hash := sha256.New()
	size, err := io.Copy(hash, file)
	if err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(hash.Sum(nil)), size, nil
}

// WriteSidecar writes <path>.sha256 in sha256sum format: the hash, two
// spaces, and the file's base name.
func WriteSidecar(path string) error {
	sum, _, err := FileSHA256(path)
	if err != nil {
		return err
	}
	line := fmt.Sprintf("%s  %s\n", sum, filepath.Base(path))
	return os.WriteFile(path+SidecarSuffix, []byte(line), 0644)
}

// VerifySidecar checks a file against <path>.sha256 and returns the file's
// SHA-256. A missing sidecar is reported as ErrNoSidecar, so the caller can
// decide whether one is required. A sidecar that is unreadable, malformed or
// does not match is an error.
//
// Only the hash on the first line is read. The file name after it is not
// compared, so a sidecar still matches after the lock is copied under another
// name.
func VerifySidecar(path string) (string, error) {
	sidecarPath := path + SidecarSuffix
	sidecar, err := os.Open(sidecarPath)
	if err != nil {
		if os.IsNotExist(err) {
			return "", fmt.Errorf("%w: %s", ErrNoSidecar, sidecarPath)
		}
		return "", fmt.Errorf("the lock sidecar could not be read: %w", err)
	}
	defer sidecar.Close()

	scanner := bufio.NewScanner(sidecar)
	if !scanner.Scan() {
		return "", errors.New("the lock sidecar is empty")
	}
	// Tolerate a byte order mark: Windows tools add one.
	fields := strings.Fields(strings.TrimPrefix(scanner.Text(), string(rune(0xFEFF))))
	if len(fields) == 0 || !IsSHA256(fields[0]) {
		return "", errors.New("the lock sidecar is not in sha256sum format")
	}
	expected := strings.ToLower(fields[0])

	actual, _, err := FileSHA256(path)
	if err != nil {
		return "", fmt.Errorf("the lock could not be read: %w", err)
	}
	if actual != expected {
		return actual, fmt.Errorf("the lock does not match its sidecar SHA-256: expected %s, got %s", expected, actual)
	}
	return actual, nil
}
