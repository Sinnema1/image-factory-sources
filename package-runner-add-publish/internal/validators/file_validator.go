// Package validators contains validation handlers for package-runner
package validators

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"

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

// Validate performs the file validation
func (v *FileValidator) Validate() (*models.ExecutionResult, error) {
	path, ok := v.params["path"].(string)
	if !ok {
		return nil, errors.New("invalid path parameter")
	}
	path = pathutil.ExpandWindowsEnv(path)

	// Check if file exists
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return &models.ExecutionResult{
				Status: models.PackageStatusValidationFailed,
			}, fmt.Errorf("file does not exist: %s", path)
		}
		return nil, fmt.Errorf("failed to check file: %w", err)
	}

	// Check if it's a regular file
	if info.IsDir() {
		return &models.ExecutionResult{
			Status: models.PackageStatusValidationFailed,
		}, fmt.Errorf("path is a directory, not a file: %s", path)
	}

	// Validate size if specified
	if size, ok := v.params["sizeBytes"]; ok {
		expectedSize, err := toInt64(size)
		if err != nil {
			return nil, fmt.Errorf("invalid sizeBytes parameter: %w", err)
		}
		if info.Size() != expectedSize {
			return &models.ExecutionResult{
				Status: models.PackageStatusValidationFailed,
			}, fmt.Errorf("file size mismatch: expected %d, got %d", expectedSize, info.Size())
		}
	}

	// Validate hash if specified
	if hash, ok := v.params["sha256"].(string); ok {
		actualHash, err := computeFileHash(path)
		if err != nil {
			return nil, fmt.Errorf("failed to compute file hash: %w", err)
		}
		if actualHash != hash {
			return &models.ExecutionResult{
				Status: models.PackageStatusValidationFailed,
			}, fmt.Errorf("file hash mismatch: expected %s, got %s", hash, actualHash)
		}
	}

	// Validate version if specified
	if version, ok := v.params["version"].(string); ok {
		actualVersion, err := getFileVersion(path)
		if err != nil {
			return &models.ExecutionResult{
				Status: models.PackageStatusValidationFailed,
			}, fmt.Errorf("failed to get file version: %w", err)
		}
		if actualVersion != version {
			return &models.ExecutionResult{
				Status: models.PackageStatusValidationFailed,
			}, fmt.Errorf("file version mismatch: expected %s, got %s", version, actualVersion)
		}
	}

	return &models.ExecutionResult{
		Status: models.PackageStatusSuccess,
	}, nil
}

func getFileVersion(filePath string) (string, error) {
	return "", nil
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
	case float64:
		return int64(v), nil
	default:
		return 0, fmt.Errorf("invalid type: %T", param)
	}
}
