//go:build !windows

package executor

import (
	"fmt"
	"path/filepath"
	"strings"

	"package-runner/internal/integrity"
	"package-runner/internal/models"
)

// processIsElevated reports whether this process holds an elevated token.
// Machine-wide installs need one; without it an MSI fails deep inside the
// installer with error 1925, which surfaces as a confusing 1603.
func processIsElevated() bool {
	return false
}

// elevated uses the configured check, or the real one.
func (e *Executor) elevated() bool {
	if e.config.ElevationCheck != nil {
		return e.config.ElevationCheck()
	}
	return processIsElevated()
}

// verifyArtifact recomputes the size and SHA-256 of a package's staged file
// and compares them with the lock. Whatever it could read of the file is kept
// in e.staged, pass or fail, so the result file records what was found and not
// what the lock said should be there.
//
// A lock entry with no sha256 is refused. An entry that cannot be checked is
// not an entry that passed.
func (e *Executor) verifyArtifact(pkg *models.LockPackage) error {
	if pkg.Artifact == nil {
		return nil
	}
	if pkg.Artifact.SizeBytes == 0 {
		return fmt.Errorf("artifact size is zero for package %s", pkg.Name)
	}
	if !integrity.IsSHA256(pkg.Artifact.SHA256) {
		return fmt.Errorf("package %s has no valid SHA-256 in the lock", pkg.Name)
	}

	path, err := e.getArtifactPath(pkg)
	if err != nil {
		return err
	}
	actual, size, err := integrity.FileSHA256(path)
	if err != nil {
		return fmt.Errorf("staged file for package %s could not be read: %w", pkg.Name, err)
	}
	e.staged[pkg.Name] = FileRecord{
		Path:      strings.TrimLeft(filepath.ToSlash(pkg.Artifact.Filename), "/"),
		SHA256:    actual,
		SizeBytes: size,
	}

	if uint64(size) != pkg.Artifact.SizeBytes {
		return fmt.Errorf("staged file for package %s is %d bytes, the lock says %d", pkg.Name, size, pkg.Artifact.SizeBytes)
	}
	if actual != strings.ToLower(pkg.Artifact.SHA256) {
		return fmt.Errorf("staged file for package %s does not match the lock: expected %s, got %s", pkg.Name, strings.ToLower(pkg.Artifact.SHA256), actual)
	}
	e.verified[pkg.Name] = true
	return nil
}
