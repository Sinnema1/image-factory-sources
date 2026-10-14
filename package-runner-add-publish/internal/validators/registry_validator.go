//go:build windows

// Package validators contains validation handlers for package-runner
package validators

import (
	"fmt"
	"reflect"
	"strings"

	"golang.org/x/sys/windows/registry"

	"package-runner/internal/logging"
	"package-runner/internal/models"
)

// RegistryValidator validates Windows registry entries
type RegistryValidator struct {
	BaseValidator
	params map[string]interface{}
}

// NewRegistryValidator creates a new RegistryValidator
func NewRegistryValidator(params map[string]interface{}) (*RegistryValidator, error) {
	if params == nil {
		return nil, &InvalidValidatorError{message: "parameters are required for registry validator"}
	}

	// Validate required parameters
	requiredParams := []string{"hive", "key", "value"}
	for _, param := range requiredParams {
		if _, ok := params[param]; !ok {
			return nil, &InvalidValidatorError{message: fmt.Sprintf("%s parameter is required for registry validator", param)}
		}
	}

	return &RegistryValidator{
		BaseValidator: BaseValidator{params: params},
		params:        params,
	}, nil
}

// SetLogger sets the logger for the validator
func (v *RegistryValidator) SetLogger(logger *logging.Logger) {
	v.BaseValidator.SetLogger(logger)
}

// Validate performs the registry validation
func (v *RegistryValidator) Validate() (*models.ExecutionResult, error) {
	hive := v.params["hive"].(string)
	keyPath := v.params["key"].(string)
	valueName := v.params["value"].(string)
	expectedData := v.params["data"]

	// Map string hive to registry Key
	var regKey registry.Key
	switch strings.ToUpper(hive) {
	case "HKLM":
		regKey = registry.LOCAL_MACHINE
	case "HKCU":
		regKey = registry.CURRENT_USER
	case "HKCR":
		regKey = registry.CLASSES_ROOT
	case "HKU":
		regKey = registry.USERS
	case "HKCC":
		regKey = registry.CURRENT_CONFIG
	default:
		return nil, fmt.Errorf("unsupported hive: %s", hive)
	}

	// Open the key
	key, err := registry.OpenKey(regKey, keyPath, registry.READ)
	if err != nil {
		return &models.ExecutionResult{
			Status: models.PackageStatusValidationFailed,
		}, fmt.Errorf("failed to open registry key: %w", err)
	}
	defer key.Close()

	// Read the value
	var actualData interface{}

	// Check the expected data type and fetch accordingly
	if _, isStr := expectedData.(string); isStr {
		actualStr, _, err := key.GetStringValue(valueName)
		if err != nil {
			return &models.ExecutionResult{
				Status: models.PackageStatusValidationFailed,
			}, fmt.Errorf("failed to read registry string value: %w", err)
		}
		actualData = actualStr
	} else if _, isInt := expectedData.(int); isInt {
		actualInt, _, err := key.GetIntegerValue(valueName)
		if err != nil {
			return &models.ExecutionResult{
				Status: models.PackageStatusValidationFailed,
			}, fmt.Errorf("failed to read registry integer value: %w", err)
		}
		actualData = int(actualInt)
	} else {
		// Default to binary data
		actualBin, _, err := key.GetBinaryValue(valueName)
		if err != nil {
			return &models.ExecutionResult{
				Status: models.PackageStatusValidationFailed,
			}, fmt.Errorf("failed to read registry binary value: %w", err)
		}
		actualData = actualBin
	}

	// Compare with expected data
	if !reflect.DeepEqual(actualData, expectedData) {
		return &models.ExecutionResult{
			Status: models.PackageStatusValidationFailed,
		}, fmt.Errorf("registry value mismatch: expected %v, got %v", expectedData, actualData)
	}

	return &models.ExecutionResult{
		Status: models.PackageStatusSuccess,
	}, nil
}

// ValidatorType returns the validator type
func (v *RegistryValidator) ValidatorType() string {
	return "registry"
}
