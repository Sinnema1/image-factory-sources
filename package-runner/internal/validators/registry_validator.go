//go:build windows

// Package validators contains validation handlers for package-runner
package validators

import (
	"errors"
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

// Validate performs the registry validation.
//
// The value is read by its own registry type, not by the type of the expected
// data, so the evidence records what is really there. With no "data"
// parameter the validation is that the value exists.
func (v *RegistryValidator) Validate() (*models.ExecutionResult, error) {
	hive, _ := v.params["hive"].(string)
	keyPath, _ := v.params["key"].(string)
	valueName, _ := v.params["value"].(string)
	expectedData, hasExpected := v.params["data"]

	b := newEvidence(v.ValidatorType(), strings.ToUpper(hive)+`\`+keyPath+`\`+valueName)
	if hive == "" || keyPath == "" {
		b.fail(errors.New("hive, key and value parameters must be strings"))
		return v.finish(b)
	}

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
		b.fail(fmt.Errorf("unsupported hive: %s", hive))
		return v.finish(b)
	}

	// Open the key
	key, err := registry.OpenKey(regKey, keyPath, registry.QUERY_VALUE)
	keyExists := err == nil
	if err != nil && !errors.Is(err, registry.ErrNotExist) {
		b.fail(fmt.Errorf("failed to open registry key: %w", err))
	}
	b.check("key_exists", true, keyExists, keyExists)

	// Read the value
	var actualData interface{}
	valueExists := false
	if keyExists {
		defer key.Close()
		var valueType string
		actualData, valueType, err = readRegistryValue(key, valueName)
		valueExists = err == nil
		if err != nil && !errors.Is(err, registry.ErrNotExist) {
			b.fail(fmt.Errorf("failed to read registry value: %w", err))
		}
		if valueExists {
			b.observe("value_type", valueType)
			b.observe("data", actualData)
		}
	}
	b.check("value_exists", true, valueExists, valueExists)

	// Compare with expected data
	if hasExpected {
		b.check("data", expectedData, actualData, valueExists && registryDataEqual(expectedData, actualData))
	}

	return v.finish(b)
}

// readRegistryValue reads a value as the type the registry stores it in.
func readRegistryValue(key registry.Key, name string) (interface{}, string, error) {
	_, valueType, err := key.GetValue(name, nil)
	if err != nil {
		return nil, "", err
	}

	switch valueType {
	case registry.SZ, registry.EXPAND_SZ:
		data, _, err := key.GetStringValue(name)
		typeName := "REG_SZ"
		if valueType == registry.EXPAND_SZ {
			typeName = "REG_EXPAND_SZ"
		}
		return data, typeName, err
	case registry.DWORD, registry.QWORD:
		data, _, err := key.GetIntegerValue(name)
		typeName := "REG_DWORD"
		if valueType == registry.QWORD {
			typeName = "REG_QWORD"
		}
		return data, typeName, err
	case registry.MULTI_SZ:
		data, _, err := key.GetStringsValue(name)
		return data, "REG_MULTI_SZ", err
	default:
		data, _, err := key.GetBinaryValue(name)
		return data, fmt.Sprintf("REG_TYPE_%d", valueType), err
	}
}

// registryDataEqual compares what the lock expects with what the registry
// holds. A lock's numbers arrive as int or float64 depending on how it was
// parsed, so integers are compared by value, not by Go type.
func registryDataEqual(expected, actual interface{}) bool {
	if actualInt, ok := actual.(uint64); ok {
		expectedInt, err := toInt64(expected)
		return err == nil && expectedInt >= 0 && uint64(expectedInt) == actualInt
	}
	if actualList, ok := actual.([]string); ok {
		expectedList, ok := expected.([]interface{})
		if !ok || len(expectedList) != len(actualList) {
			return false
		}
		for i := range expectedList {
			if expectedList[i] != actualList[i] {
				return false
			}
		}
		return true
	}
	return reflect.DeepEqual(expected, actual)
}

// ValidatorType returns the validator type
func (v *RegistryValidator) ValidatorType() string {
	return "registry"
}
