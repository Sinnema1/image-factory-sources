// Package validators contains validation handlers for package-runner
package validators

import (
	"fmt"
	"package-runner/internal/logging"
	"package-runner/internal/models"
	"strings"
)

// Validator is the interface all validators must implement
type Validator interface {
	Validate() (*models.ExecutionResult, error)
	ValidatorType() string
	SetLogger(logger *logging.Logger)
}

// ValidationResult represents the detailed result of a validation
type ValidationResult struct {
	ValidatorType string                 `json:"validatorType"`
	Parameters    map[string]interface{} `json:"parameters,omitempty"`
	Passed        bool                   `json:"passed"`
	Reason        string                 `json:"reason,omitempty"`
	Details       map[string]interface{} `json:"details,omitempty"`
}

// BaseValidator provides common functionality for all validators
type BaseValidator struct {
	logger *logging.Logger
	params map[string]interface{}
}

// SetLogger sets the logger for the validator
func (v *BaseValidator) SetLogger(logger *logging.Logger) {
	v.logger = logger
}

// logDebug logs a debug message with optional fields
func (v *BaseValidator) logDebug(message string, fields logging.Fields) {
	if v.logger != nil {
		v.logger.Debug(message, fields)
	}
}

// logInfo logs an info message with optional fields
func (v *BaseValidator) logInfo(message string, fields logging.Fields) {
	if v.logger != nil {
		v.logger.Info(message, fields)
	}
}

// logWarn logs a warning message with optional fields
func (v *BaseValidator) logWarn(message string, fields logging.Fields) {
	if v.logger != nil {
		v.logger.Warn(message, fields)
	}
}

// logError logs an error message with optional fields
func (v *BaseValidator) logError(message string, fields logging.Fields) {
	if v.logger != nil {
		v.logger.Error(message, fields)
	}
}

// logValidationResult logs a validation result for evidence collection
func (v *BaseValidator) logValidationResult(validatorType string, passed bool, reason string, details map[string]interface{}) {
	if v.logger == nil {
		return
	}

	field := logging.Fields{
		"validator_type": validatorType,
		"passed":         passed,
		"reason":         reason,
	}

	// Add all details to fields for evidence
	for k, val := range details {
		field["detail_"+k] = val
	}

	if passed {
		v.logger.Info("Validation passed", field)
	} else {
		v.logger.Error("Validation failed", field)
	}
}

// NewValidator creates a new validator based on handler type and parameters
func NewValidator(handlerType string, params map[string]interface{}, logger *logging.Logger) (Validator, error) {
	var validator Validator
	var err error

	switch strings.ToLower(handlerType) {
	case "file":
		validator, err = NewFileValidator(params)
	case "registry":
		validator, err = NewRegistryValidator(params)
	case "service":
		validator, err = NewServiceValidator(params)
	case "command":
		validator, err = NewCommandValidator(params)
	default:
		return nil, fmt.Errorf("unknown validator type: %s", handlerType)
	}

	if err != nil {
		return nil, err
	}

	if logger != nil {
		validator.SetLogger(logger)
	}

	return validator, nil
}

// InvalidValidatorError represents an error with validator configuration
type InvalidValidatorError struct {
	message string
}

func (e *InvalidValidatorError) Error() string {
	return e.message
}

// GetValidatorTypes returns a list of all supported validator types
func GetValidatorTypes() []string {
	return []string{"file", "registry", "service", "command"}
}

// Helper functions for parameter extraction
func getStringParam(params map[string]interface{}, key string) (string, bool) {
	val, ok := params[key]
	if !ok {
		return "", false
	}
	if str, ok := val.(string); ok {
		return str, true
	}
	return "", false
}

func getStringParamWithDefault(params map[string]interface{}, key, defaultValue string) string {
	if val, ok := getStringParam(params, key); ok {
		return val
	}
	return defaultValue
}

func getInt64Param(params map[string]interface{}, key string) (int64, bool) {
	val, ok := params[key]
	if !ok {
		return 0, false
	}

	switch v := val.(type) {
	case int:
		return int64(v), true
	case int64:
		return v, true
	case float64:
		return int64(v), true
	}
	return 0, false
}

func getBoolParam(params map[string]interface{}, key string) (bool, bool) {
	val, ok := params[key]
	if !ok {
		return false, false
	}
	if b, ok := val.(bool); ok {
		return b, true
	}
	return false, false
}

func getStringSliceParam(params map[string]interface{}, key string) ([]string, bool) {
	val, ok := params[key]
	if !ok {
		return nil, false
	}

	if slice, ok := val.([]interface{}); ok {
		result := make([]string, len(slice))
		for i, item := range slice {
			if str, ok := item.(string); ok {
				result[i] = str
			} else {
				return nil, false
			}
		}
		return result, true
	}

	return nil, false
}
