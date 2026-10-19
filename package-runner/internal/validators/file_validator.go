// Package validators contains validation handlers for package-runner
package validators

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"package-runner/internal/logging"
	"package-runner/internal/models"
	"package-runner/internal/pathutil"
)

// FileValidator validates file existence, version, hash, and size
type FileValidator struct {
	BaseValidator
	params map[string]interface{}
}

// NewFileValidator creates a new FileValidator
func NewFileValidator(params map[string]interface{}) (*FileValidator, error) {
	if params == nil {
		return nil, &InvalidValidatorError{message: "parameters are required for file validator"}
	}

	// Validate required parameters
	if _, ok := params["path"]; !ok {
		return nil, &InvalidValidatorError{message: "path parameter is required for file validator"}
	}

	return &FileValidator{
		BaseValidator: BaseValidator{params: params},
		params:        params,
	}, nil
}

// SetLogger sets the logger for the validator
func (v *FileValidator) SetLogger(logger *logging.Logger) {
	v.BaseValidator.SetLogger(logger)
}

// Validate performs the file validation.
//
// Every check the parameters ask for is recorded, even when the file is
// missing, and the file's hash, size, modified time and version resource are
// recorded as observed facts whether or not the lock asked to compare them.
func (v *FileValidator) Validate() (*models.ExecutionResult, error) {
	path, ok := v.params["path"].(string)
	if !ok {
		b := newEvidence(v.ValidatorType(), fmt.Sprint(v.params["path"]))
		b.fail(errors.New("invalid path parameter"))
		return v.finish(b)
	}
	path = pathutil.ExpandWindowsEnv(path)
	b := newEvidence(v.ValidatorType(), path)

	// Check that the path is a regular file
	info, err := os.Stat(path)
	exists := err == nil && !info.IsDir()
	switch {
	case err != nil && !os.IsNotExist(err):
		b.fail(fmt.Errorf("failed to check file: %w", err))
	case err == nil && info.IsDir():
		b.fail(fmt.Errorf("path is a directory, not a file: %s", path))
	}
	b.check("exists", true, exists, exists)

	// Observe the file, so the evidence says what is on disk
	var actualSize interface{}
	var actualHash interface{}
	var version versionInfo
	var versionErr error
	if exists {
		actualSize = info.Size()
		b.observe("size_bytes", info.Size())
		b.observe("modified_utc", info.ModTime().UTC().Format(time.RFC3339))

		hash, hashErr := computeFileHash(path)
		if hashErr != nil {
			b.fail(fmt.Errorf("failed to compute file hash: %w", hashErr))
		} else {
			actualHash = hash
			b.observe("sha256", hash)
		}

		// Not every file has a version resource, so failing to read one only
		// matters if the lock asked for a version.
		version, versionErr = readVersionInfo(path)
		b.observe("file_version", version.FileVersion)
		b.observe("product_name", version.ProductName)
		b.observe("company_name", version.CompanyName)
	}

	// Validate size if specified
	if size, ok := v.params["sizeBytes"]; ok {
		expectedSize, err := toInt64(size)
		if err != nil {
			b.fail(fmt.Errorf("invalid sizeBytes parameter: %w", err))
			b.check("size_bytes", size, actualSize, false)
		} else {
			b.check("size_bytes", expectedSize, actualSize, exists && info.Size() == expectedSize)
		}
	}

	// Validate hash if specified
	if hash, ok := v.params["sha256"].(string); ok {
		actual, _ := actualHash.(string)
		b.check("sha256", strings.ToLower(hash), actualHash, actual != "" && strings.EqualFold(actual, hash))
	}

	// Validate version if specified
	if expectedVersion, ok := v.params["version"].(string); ok {
		var actualVersion interface{}
		if exists && versionErr == nil {
			actualVersion = version.FileVersion
		} else if exists {
			b.fail(fmt.Errorf("failed to get file version: %w", versionErr))
		}
		b.check("version", expectedVersion, actualVersion, actualVersion == expectedVersion)
	}

	return v.finish(b)
}

// versionInfo is what a file's version resource says about it.
type versionInfo struct {
	FileVersion string
	ProductName string
	CompanyName string
}

// ValidatorType returns the validator type
func (v *FileValidator) ValidatorType() string {
	return "file"
}

// computeFileHash computes the SHA256 hash of a file
func computeFileHash(filePath string) (string, error) {
	file, err := os.Open(filePath)
	if err != nil {
		return "", err
	}
	defer file.Close()

	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}

	return hex.EncodeToString(hash.Sum(nil)), nil
}

// toInt64 converts a parameter to int64
func toInt64(param interface{}) (int64, error) {
	switch v := param.(type) {
	case int:
		return int64(v), nil
	case int64:
		return v, nil
	case uint64:
		return int64(v), nil
	case float64:
		return int64(v), nil
	default:
		return 0, fmt.Errorf("invalid type: %T", param)
	}
}
