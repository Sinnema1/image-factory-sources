//go:build !windows

// Package validators contains validation handlers for package-runner
package validators

import (
	"fmt"

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
	return nil,
		fmt.Errorf("Registry validation only supported on Windows")
}

// ValidatorType returns the validator type
func (v *RegistryValidator) ValidatorType() string {
	return "registry"
}
