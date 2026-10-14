// Package validators contains validation handlers for package-runner
package validators

import (
	"errors"
	"fmt"
	"strings"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"

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
	serviceName, ok := v.params["serviceName"].(string)
	if !ok {
		b := newEvidence(v.ValidatorType(), fmt.Sprint(v.params["serviceName"]))
		b.fail(errors.New("invalid serviceName parameter"))
		return v.finish(b)
	}
	b := newEvidence(v.ValidatorType(), serviceName)

	// Get expected state
	expectedState, hasState := v.params["state"].(string)
	if !hasState {
		b.fail(errors.New("state parameter is required for service validator"))
	}

	// Get expected start type if specified
	expectedStartType, hasStartType := v.params["startType"].(string)

	// Query only: the validator must work without rights to change services.
	var actualState, actualStartType interface{}
	service, err := openServiceForQuery(serviceName)
	exists := err == nil
	if err != nil && !errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST) {
		b.fail(fmt.Errorf("failed to open service: %w", err))
	}
	b.check("exists", true, exists, exists)

	if exists {
		defer service.Close()

		if status, err := service.Query(); err != nil {
			b.fail(fmt.Errorf("failed to query service status: %w", err))
		} else {
			actualState = serviceStateName(status.State)
			b.observe("state", actualState)
		}

		if config, err := service.Config(); err != nil {
			b.fail(fmt.Errorf("failed to query service configuration: %w", err))
		} else {
			actualStartType = serviceStartTypeName(config.StartType)
			b.observe("start_type", actualStartType)
			b.observe("display_name", config.DisplayName)
		}
	}

	if hasState {
		actual, _ := actualState.(string)
		b.check("state", strings.ToLower(expectedState), actualState, actual != "" && strings.EqualFold(actual, expectedState))
	}
	if hasStartType {
		actual, _ := actualStartType.(string)
		b.check("start_type", strings.ToLower(expectedStartType), actualStartType, actual != "" && strings.EqualFold(actual, expectedStartType))
	}

	return v.finish(b)
}

// openServiceForQuery opens a service with the least access that can read its
// status and configuration.
func openServiceForQuery(name string) (*mgr.Service, error) {
	manager, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_CONNECT)
	if err != nil {
		return nil, err
	}
	defer windows.CloseServiceHandle(manager)

	namePtr, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return nil, err
	}
	handle, err := windows.OpenService(manager, namePtr, windows.SERVICE_QUERY_STATUS|windows.SERVICE_QUERY_CONFIG)
	if err != nil {
		return nil, err
	}
	return &mgr.Service{Name: name, Handle: handle}, nil
}

func serviceStateName(state svc.State) string {
	switch state {
	case svc.Stopped:
		return "stopped"
	case svc.StartPending:
		return "start_pending"
	case svc.StopPending:
		return "stop_pending"
	case svc.Running:
		return "running"
	case svc.ContinuePending:
		return "continue_pending"
	case svc.PausePending:
		return "pause_pending"
	case svc.Paused:
		return "paused"
	default:
		return fmt.Sprintf("unknown_%d", state)
	}
}

func serviceStartTypeName(startType uint32) string {
	switch startType {
	case mgr.StartAutomatic:
		return "automatic"
	case mgr.StartManual:
		return "manual"
	case mgr.StartDisabled:
		return "disabled"
	case windows.SERVICE_BOOT_START:
		return "boot"
	case windows.SERVICE_SYSTEM_START:
		return "system"
	default:
		return fmt.Sprintf("unknown_%d", startType)
	}
}

// ValidatorType returns the validator type
func (v *ServiceValidator) ValidatorType() string {
	return "service"
}
