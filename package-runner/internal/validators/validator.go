// Package validators contains validation handlers for package-runner
package validators

import (
	"errors"
	"fmt"
	"os"
	"package-runner/internal/logging"
	"package-runner/internal/models"
	"strings"
	"time"
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

// evidenceBuilder collects the checks a validator makes and the facts it
// observes. Validators record every check they were asked to make, including
// the ones that cannot pass because an earlier one failed, so checks_total
// always says how much was asked for.
type evidenceBuilder struct {
	evidence models.ValidationEvidence
	start    time.Time
	err      error
}

// newEvidence starts an evidence record for one validator run.
func newEvidence(validatorType, target string) *evidenceBuilder {
	host, _ := os.Hostname()
	return &evidenceBuilder{
		evidence: models.ValidationEvidence{
			Validator: validatorType,
			Target:    target,
			Host:      host,
			Checks:    []models.ValidationCheck{},
		},
		start: time.Now(),
	}
}

// check records one comparison.
func (b *evidenceBuilder) check(name string, expected, actual interface{}, passed bool) {
	b.evidence.Checks = append(b.evidence.Checks, models.ValidationCheck{
		Name:     name,
		Expected: expected,
		Actual:   actual,
		Passed:   passed,
	})
}

// observe records a fact about the target that was not necessarily compared
// against anything. Empty strings are left out.
func (b *evidenceBuilder) observe(key string, value interface{}) {
	if text, ok := value.(string); ok && text == "" {
		return
	}
	if b.evidence.Observed == nil {
		b.evidence.Observed = make(map[string]interface{})
	}
	b.evidence.Observed[key] = value
}

// fail records a problem that stopped the validator from checking properly,
// such as a parameter it could not read. The first one is kept.
func (b *evidenceBuilder) fail(err error) {
	if b.err == nil {
		b.err = err
	}
}

// finish closes the record, logs it, and returns it in an ExecutionResult.
// A validator passes only if it made at least one check, every check passed,
// and nothing stopped it. The returned error is nil only on a pass.
func (v *BaseValidator) finish(b *evidenceBuilder) (*models.ExecutionResult, error) {
	evidence := &b.evidence
	evidence.Timestamp = time.Now().UTC()
	evidence.DurationMS = time.Since(b.start).Milliseconds()
	evidence.ChecksTotal = len(evidence.Checks)
	evidence.ChecksPassed = 0
	var firstFailed *models.ValidationCheck
	for i := range evidence.Checks {
		if evidence.Checks[i].Passed {
			evidence.ChecksPassed++
		} else if firstFailed == nil {
			firstFailed = &evidence.Checks[i]
		}
	}

	err := b.err
	if err == nil && firstFailed != nil {
		err = fmt.Errorf("%s check failed: expected %v, got %v", firstFailed.Name, firstFailed.Expected, firstFailed.Actual)
	}
	if err == nil && evidence.ChecksTotal == 0 {
		err = errors.New("validator made no checks")
	}

	status := models.PackageStatusSuccess
	evidence.Result = models.ValidationResultPassed
	if err != nil {
		status = models.PackageStatusValidationFailed
		evidence.Result = models.ValidationResultFailed
		evidence.Error = err.Error()
	}

	LogEvidence(v.logger, *evidence)

	result := &models.ExecutionResult{
		Status:      status,
		Duration:    time.Since(b.start),
		Timestamp:   evidence.Timestamp,
		Validations: []models.ValidationEvidence{*evidence},
	}
	if err != nil {
		return result, fmt.Errorf("%s validation failed for %s: %w", evidence.Validator, evidence.Target, err)
	}
	return result, nil
}

// LogEvidence writes one "validation.evidence" entry: INFO for a pass, ERROR
// for a failure. Observed facts are flattened to "observed.<name>" fields.
func LogEvidence(logger *logging.Logger, evidence models.ValidationEvidence) {
	if logger == nil {
		return
	}

	fields := logging.Fields{
		"event":         "validation.evidence",
		"validator":     evidence.Validator,
		"target":        evidence.Target,
		"result":        evidence.Result,
		"host":          evidence.Host,
		"duration_ms":   evidence.DurationMS,
		"checks":        evidence.Checks,
		"checks_passed": evidence.ChecksPassed,
		"checks_total":  evidence.ChecksTotal,
	}
	for key, value := range evidence.Observed {
		fields["observed."+key] = value
	}
	if evidence.Error != "" {
		fields["error"] = evidence.Error
	}

	message := fmt.Sprintf("Validation %s: %s %s", evidence.Result, evidence.Validator, evidence.Target)
	if evidence.Result == models.ValidationResultPassed {
		logger.Info(message, fields)
	} else {
		logger.Error(message, fields)
	}
}

// FailedEvidence builds the record for a validator that could not be created
// or run at all, so a validation the lock asked for never goes missing from
// the evidence.
func FailedEvidence(validatorType string, err error) models.ValidationEvidence {
	b := newEvidence(validatorType, "")
	b.evidence.Result = models.ValidationResultFailed
	b.evidence.Error = err.Error()
	b.evidence.Timestamp = time.Now().UTC()
	return b.evidence
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
