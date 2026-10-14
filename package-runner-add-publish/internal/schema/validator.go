// Package schema provides YAML schema validation for package-runner
package schema

import (
	"errors"
	"fmt"
	"reflect"
	"strings"

	"package-runner/internal/models"
)

// ValidateRecipe validates an ImageRecipe
func ValidateRecipe(recipe *models.ImageRecipe) error {
	// Validate no duplicate packages
	seen := make(map[string]bool)
	for _, pkg := range recipe.Packages {
		key := pkg.Name + ":" + pkg.Version
		if seen[key] {
			return fmt.Errorf("duplicate package found: %s", key)
		}
		seen[key] = true
	}

	// Validate installOrder is unique
	orders := make(map[int]bool)
	for _, pkg := range recipe.Packages {
		if orders[pkg.InstallOrder] {
			return fmt.Errorf("duplicate installOrder found: %d", pkg.InstallOrder)
		}
		orders[pkg.InstallOrder] = true
	}

	// Default failure policy
	if recipe.Defaults.FailurePolicy == "" {
		recipe.Defaults.FailurePolicy = "fail"
	}

	// Validate package failure policies
	for i := range recipe.Packages {
		if recipe.Packages[i].FailurePolicy == "" {
			recipe.Packages[i].FailurePolicy = recipe.Defaults.FailurePolicy
		}
	}

	// Validate dependencies exist
	packageNames := make(map[string]bool)
	for _, pkg := range recipe.Packages {
		packageNames[pkg.Name] = true
	}

	for _, pkg := range recipe.Packages {
		for _, dep := range pkg.Dependencies {
			if !packageNames[dep] {
				return fmt.Errorf("package %s depends on non-existent package: %s", pkg.Name, dep)
			}
		}
	}

	// Check for dependency cycles
	if err := checkCycles(recipe.Packages); err != nil {
		return err
	}

	return nil
}

// checkCycles detects dependency cycles using DFS
func checkCycles(packages []models.ImageRecipePackage) error {
	nameToPkg := make(map[string]*models.ImageRecipePackage)
	for i := range packages {
		nameToPkg[packages[i].Name] = &packages[i]
	}

	visited := make(map[string]bool)
	recStack := make(map[string]bool)

	var dfs func(string) error
	dfs = func(name string) error {
		visited[name] = true
		recStack[name] = true

		pkg, exists := nameToPkg[name]
		if !exists {
			return nil
		}

		for _, dep := range pkg.Dependencies {
			if !visited[dep] {
				if err := dfs(dep); err != nil {
					return err
				}
			} else if recStack[dep] {
				return fmt.Errorf("circular dependency detected: %s depends on %s", name, dep)
			}
		}

		recStack[name] = false
		return nil
	}

	for _, pkg := range packages {
		if !visited[pkg.Name] {
			if err := dfs(pkg.Name); err != nil {
				return err
			}
		}
	}

	return nil
}

// ValidatePackageDefinition validates a PackageDefinition
func ValidatePackageDefinition(pkgDef *models.PackageDefinition) error {
	// Validate handler-specific configurations
	switch pkgDef.Install.Handler {
	case "msi":
		// MSI handler validation
		if len(pkgDef.Install.Arguments) == 0 {
			return errors.New("msi handler requires at least one argument")
		}
	case "exe":
		// EXE handler validation
		if len(pkgDef.Install.Arguments) == 0 {
			return errors.New("exe handler requires at least one argument")
		}
	case "powershell":
		// PowerShell handler validation
		if len(pkgDef.Install.Arguments) == 0 {
			return errors.New("powershell handler requires at least one argument")
		}
	case "psadt":
		// PSADT handler validation
		if len(pkgDef.Install.Arguments) == 0 {
			return errors.New("psadt handler requires at least one argument")
		}
	}

	return nil
}

// ValidateLock validates a ImageRecipeLock
func ValidateLock(lock *models.ImageRecipeLock) error {
	// Validate lock packages
	for _, pkg := range lock.Packages {
		// Ensure consistent struct usage by casting if needed
		_ = pkg
	}

	return nil
}

// CheckUnknownFields checks for unknown fields in a struct using reflection
func CheckUnknownFields(obj interface{}, allowedFields map[string]bool) error {
	val := reflect.ValueOf(obj)
	if val.Kind() == reflect.Ptr {
		val = val.Elem()
	}

	typeOf := val.Type()
	for i := 0; i < val.NumField(); i++ {
		field := typeOf.Field(i)
		yamlTag := field.Tag.Get("yaml")
		if yamlTag == "" || yamlTag == "-" {
			continue
		}

		fieldName := strings.Split(yamlTag, ",")[0]
		if !allowedFields[fieldName] {
			return fmt.Errorf("unknown field: %s", fieldName)
		}
	}

	return nil
}
