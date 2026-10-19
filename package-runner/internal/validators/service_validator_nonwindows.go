//go:build !windows

// Package validators contains validation handlers for package-runner
package validators

import (
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

// Validate performs the service validation: the service exists, is in the
// expected state and, if asked, has the expected start type.
//
// States are stopped, start_pending, stop_pending, running, continue_pending,
// pause_pending and paused. Start types are boot, system, automatic, manual
// and disabled. Both are compared without regard to case.
func (v *ServiceValidator) Validate() (*models.ExecutionResult, error) {
	return nil, fmt.Errorf("this CLI command can only be run on windows OS")

}

// ValidatorType returns the validator type
func (v *ServiceValidator) ValidatorType() string {
	return "service"
}
