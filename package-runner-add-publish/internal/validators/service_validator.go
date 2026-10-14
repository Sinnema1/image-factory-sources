// Package validators contains validation handlers for package-runner
package validators

import (
	"errors"
	"fmt"

	"package-runner/internal/logging"
	"package-runner/internal/models"
)

// ServiceValidator validates Windows service status
type ServiceValidator struct {
	BaseValidator
	params map[string]interface{}
}

// NewServiceValidator creates a new ServiceValidator
func NewServiceValidator(params map[string]interface{}) (*ServiceValidator, error) {
	if params == nil {
		return nil, &InvalidValidatorError{message: "parameters are required for service validator"}
	}

	// Validate required parameters
	if _, ok := params["serviceName"]; !ok {
		return nil, &InvalidValidatorError{message: "serviceName parameter is required for service validator"}
	}

	return &ServiceValidator{
		BaseValidator: BaseValidator{params: params},
		params:        params,
	}, nil
}

// SetLogger sets the logger for the validator
func (v *ServiceValidator) SetLogger(logger *logging.Logger) {
	v.BaseValidator.SetLogger(logger)
}

// Validate performs the service validation
func (v *ServiceValidator) Validate() (*models.ExecutionResult, error) {
	serviceName, ok := v.params["serviceName"].(string)
	if !ok {
		return nil, errors.New("invalid serviceName parameter")
	}

	// Get expected state
	expectedState, ok := v.params["state"]
	if !ok {
		return nil, errors.New("state parameter is required for service validator")
	}

	// Get expected start type if specified
	expectedStartType, _ := v.params["startType"].(string)

	// TODO: Implement actual Windows service check
	// This would use golang.org/x/sys/windows/svc package or similar
	// For now, we'll simulate the validation

	// In a real implementation, we would:
	// 1. Open the service control manager
	// 2. Open the service
	// 3. Query the service status
	// 4. Compare with expected state and start type

	// Simulate successful validation for now
	// In production, this would be replaced with actual service access
	fmt.Printf("Service validation simulated: serviceName=%s, expectedState=%v, expectedStartType=%s\n",
		serviceName, expectedState, expectedStartType)

	return &models.ExecutionResult{
		Status: models.PackageStatusSuccess,
	}, nil
}

// ValidatorType returns the validator type
func (v *ServiceValidator) ValidatorType() string {
	return "service"
}
