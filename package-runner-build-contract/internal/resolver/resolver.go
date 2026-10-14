// Package resolver handles dependency resolution and lock file creation for package-runner
//go:build windows || linux

package resolver

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"package-runner/internal/logging"
	"package-runner/internal/integrity"
	"package-runner/internal/models"

	"gopkg.in/yaml.v3"
)

// packageKey creates a unique key for a package using name@version format
func packageKey(name, version string) string {
	return fmt.Sprintf("%s@%s", name, version)
}

// ResolveOptions contains options for the resolve operation
type ResolveOptions struct {
	RecipePath  string
	PackageRoot string
	OutputPath  string
	Logger      *logging.Logger
}

// ResolveResult contains the result of a resolve operation
type ResolveResult struct {
	LockPath string
	Packages []*models.LockPackage
}

// Resolve performs complete package resolution from recipe to lock file
func Resolve(ctx context.Context, options *ResolveOptions) (*ResolveResult, error) {
	// Validate options
	if options == nil {
		return nil, fmt.Errorf("resolve options cannot be nil")
	}

	if options.RecipePath == "" {
		return nil, fmt.Errorf("recipe path is required")
	}

	if options.PackageRoot == "" {
		return nil, fmt.Errorf("package root is required")
	}

	if options.OutputPath == "" {
		return nil, fmt.Errorf("output path is required")
	}

	// Get logger or create default
	logger := options.Logger
	if logger == nil {
		logger = logging.NewDefaultLogger()
	}

	logger.Info("Starting package resolution", map[string]interface{}{
		"recipePath":  options.RecipePath,
		"packageRoot": options.PackageRoot,
		"outputPath":  options.OutputPath,
	})

	// Load the recipe
	recipe, err := models.LoadImageRecipe(options.RecipePath)
	if err != nil {
		return nil, fmt.Errorf("failed to load recipe: %w", err)
	}

	logger.Info("Loaded image recipe", map[string]interface{}{
		"name":       recipe.Metadata.Name,
		"version":    recipe.Metadata.Version,
		"apiVersion": recipe.APIVersion,
		"platform":   recipe.Target.Platform,
	})

	// Calculate recipe hash
	recipeData, err := os.ReadFile(options.RecipePath)
	if err != nil {
		return nil, fmt.Errorf("failed to read recipe for hashing: %w", err)
	}
	atten_hash := sha256.Sum256(recipeData)
	recipeHash := fmt.Sprintf("sha256:%s", hex.EncodeToString(atten_hash[:]))
	logger.Info("Calculated recipe hash", map[string]interface{}{"hash": recipeHash})

	// Validate recipe schema
	if err := validateRecipe(recipe); err != nil {
		return nil, fmt.Errorf("recipe validation failed: %w", err)
	}

	// Load ALL package definitions from the package root
	packageDefs, defPaths, err := loadAllPackageDefinitions(options.PackageRoot)
	if err != nil {
		return nil, fmt.Errorf("failed to load package definitions: %w", err)
	}

	logger.Info("Loaded package definitions", map[string]interface{}{
		"count": len(packageDefs),
	})

	// Validate all package definitions
	for i, def := range packageDefs {
		if err := validatePackageDefinition(def); err != nil {
			return nil, fmt.Errorf("package definition validation failed for %s: %w", defPaths[i], err)
		}
	}

	// Build package map for quick lookup (exact name@version only)
	packageMap := make(map[string]*models.PackageDefinition)
	definitionPaths := make(map[string]string)
	for i, pkg := range packageDefs {
		key := packageKey(pkg.Metadata.Name, pkg.Metadata.Version)
		if _, exists := packageMap[key]; exists {
			return nil, fmt.Errorf("duplicate package definition: %s", key)
		}
		packageMap[key] = pkg
		definitionPaths[key] = defPaths[i]
	}

	logger.Info("Built package map", map[string]interface{}{
		"uniquePackages": len(packageMap),
	})

	// Resolve recipe packages to lock packages (exact name@version matching ONLY)
	lockPackages, err := resolveRecipePackages(recipe, packageMap, definitionPaths)
	if err != nil {
		return nil, fmt.Errorf("failed to resolve recipe packages: %w", err)
	}

	logger.Info("Resolved recipe packages", map[string]interface{}{
		"resolvedCount": len(lockPackages),
		"recipeCount":   len(recipe.Packages),
	})

	// Perform topological sort to handle dependencies and detect cycles
	sortedPackages, err := topologicalSort(lockPackages)
	if err != nil {
		return nil, fmt.Errorf("dependency resolution failed: %w", err)
	}

	logger.Info("Topological sort complete", map[string]interface{}{
		"sortedCount": len(sortedPackages),
	})

	// Validate all dependencies are satisfied
	if err := validateDependencyResolution(sortedPackages, packageMap); err != nil {
		return nil, fmt.Errorf("dependency validation failed: %w", err)
	}

	// Create lock file structure
	lock := createLockFile(recipe, sortedPackages, recipeHash)

	// Calculate lock hash
	lockHash, err := models.CalculateLockHash(lock)
	if err != nil {
		return nil, fmt.Errorf("failed to calculate lock hash: %w", err)
	}
	lock.Metadata.LockHash = lockHash

	logger.Info("Calculated lock hash", map[string]interface{}{"hash": lockHash})

	// Write lock file
	if err := writeLockFile(options.OutputPath, lock); err != nil {
		return nil, fmt.Errorf("failed to write lock file: %w", err)
	}

	logger.Info("Resolution complete", map[string]interface{}{
		"lockPath":     options.OutputPath,
		"packageCount": len(sortedPackages),
	})

	return &ResolveResult{
		LockPath: options.OutputPath,
		Packages: sortedPackages,
	}, nil
}

// validateRecipe validates the basic structure of an ImageRecipe
func validateRecipe(recipe *models.ImageRecipe) error {
	if recipe.APIVersion == "" {
		return fmt.Errorf("apiVersion must be specified")
	}

	if recipe.Kind != "ImageRecipe" {
		return fmt.Errorf("kind must be ImageRecipe, got: %s", recipe.Kind)
	}

	if recipe.Metadata.Name == "" {
		return fmt.Errorf("metadata.name must be specified")
	}

	if recipe.Metadata.Version == "" {
		return fmt.Errorf("metadata.version must be specified")
	}

	if recipe.Target.Platform == "" {
		return fmt.Errorf("target.platform must be specified")
	}

	// Check for duplicate packages in recipe
	seen := make(map[string]bool)
	for _, pkg := range recipe.Packages {
		key := packageKey(pkg.Name, pkg.Version)
		if seen[key] {
			return fmt.Errorf("duplicate package in recipe: %s", key)
		}
		seen[key] = true
	}

	return nil
}

// validatePackageDefinition validates a PackageDefinition structure
func validatePackageDefinition(pkg *models.PackageDefinition) error {
	if pkg.APIVersion == "" {
		return fmt.Errorf("apiVersion must be specified")
	}

	if pkg.Kind != "PackageDefinition" {
		return fmt.Errorf("kind must be PackageDefinition, got: %s", pkg.Kind)
	}

	if pkg.Metadata.Name == "" {
		return fmt.Errorf("metadata.name must be specified")
	}

	if pkg.Metadata.Version == "" {
		return fmt.Errorf("metadata.version must be specified")
	}

	// Install is required and should be validated by schema
	if pkg.Install.Handler == "" {
		return fmt.Errorf("install.handler must be specified")
	}

	if !models.IsValidHandlerType(pkg.Install.Handler) {
		return fmt.Errorf("invalid handler type: %s", pkg.Install.Handler)
	}

	// Validate artifact information
	if pkg.Artifact == nil {
		return fmt.Errorf("artifact configuration must be specified")
	}

	if pkg.Artifact.Filename == "" {
		return fmt.Errorf("artifact.filename must be specified")
	}

	if pkg.Artifact.SHA256 == "" {
		return fmt.Errorf("artifact.sha256 must be specified")
	}

	if pkg.Artifact.SizeBytes <= 0 {
		return fmt.Errorf("artifact.sizeBytes must be positive")
	}

	return nil
}

// loadAllPackageDefinitions loads ALL package definitions from the package root directory
func loadAllPackageDefinitions(packageRoot string) ([]*models.PackageDefinition, []string, error) {
	var packageDefs []*models.PackageDefinition
	var defPaths []string

	err := filepath.Walk(packageRoot, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return fmt.Errorf("error accessing path %s: %w", path, err)
		}

		// Skip directories
		if info.IsDir() {
			return nil
		}

		// Only process YAML files
		ext := strings.ToLower(filepath.Ext(path))
		if ext != ".yaml" && ext != ".yml" {
			return nil
		}

		// Load package definition
		packageDef, err := models.LoadPackageDefinition(path)
		if err != nil {
			fmt.Printf("Warning: failed to load package definition from %s: %v\n", path, err)
			return nil
		}

		// Only include actual PackageDefinitions
		if packageDef.Kind == "PackageDefinition" {
			packageDefs = append(packageDefs, packageDef)
			defPaths = append(defPaths, path)
		}

		return nil
	})

	if err != nil {
		return nil, nil, fmt.Errorf("failed to walk package root directory %s: %w", packageRoot, err)
	}

	if len(packageDefs) == 0 {
		return nil, nil, fmt.Errorf("no package definitions found in %s", packageRoot)
	}

	return packageDefs, defPaths, nil
}

// resolveRecipePackages resolves each package in the recipe to a PackageDefinition
// Performs EXACT name@version matching ONLY - no wildcard matching
func resolveRecipePackages(recipe *models.ImageRecipe, packageMap map[string]*models.PackageDefinition, defPaths map[string]string) ([]*models.LockPackage, error) {
	var lockPackages []*models.LockPackage
	defaultFailurePolicy := "fail"

	if recipe.Defaults.FailurePolicy != "" {
		defaultFailurePolicy = recipe.Defaults.FailurePolicy
	}

	for _, pkg := range recipe.Packages {
		// Merge with defaults
		if pkg.FailurePolicy == "" {
			pkg.FailurePolicy = defaultFailurePolicy
		}

		key := packageKey(pkg.Name, pkg.Version)

		// Perform EXACT matching - no wildcards, no version ranges
		def, exists := packageMap[key]
		if !exists {
			return nil, fmt.Errorf("package not found in package root: %s", key)
		}

		// Create lock package from recipe + definition
		lockPkg := &models.LockPackage{
			Name:          pkg.Name,
			Version:       pkg.Version,
			InstallOrder:  pkg.InstallOrder,
			Dependencies:  pkg.Dependencies,
			FailurePolicy: pkg.FailurePolicy,
			// RestartBehavior defaults to "" if not specified
			ResolvedFrom: defPaths[key], // Record source definition path
			Install:      def.Install,
			Validation:   def.Validation,
			Artifact:     def.Artifact,
		}

		lockPackages = append(lockPackages, lockPkg)
	}

	return lockPackages, nil
}

// topologicalSort performs topological sort on packages by dependencies
// Returns sorted packages and detects cycles
func topologicalSort(packages []*models.LockPackage) ([]*models.LockPackage, error) {
	// Build dependency graph
	graph := make(map[string][]string)  // package -> dependencies
	inDegree := make(map[string]int)    // package -> number of incoming edges
	packageSet := make(map[string]bool) // all package keys

	// Initialize
	for _, pkg := range packages {
		key := packageKey(pkg.Name, pkg.Version)
		packageSet[key] = true
		inDegree[key] = 0
		graph[key] = pkg.Dependencies
	}

	// Calculate in-degree for each node
	for key := range packageSet {
		for _, dep := range graph[key] {
			if packageSet[dep] {
				inDegree[key]++
			} else {
				return nil, fmt.Errorf("dependency not found in package set: %s required by %s", dep, key)
			}
		}
	}

	// Kahn's algorithm for topological sort
	var queue []string
	for key, degree := range inDegree {
		if degree == 0 {
			queue = append(queue, key)
		}
	}

	var sorted []*models.LockPackage
	sortedKeys := make(map[string]bool)
	packageByKey := make(map[string]*models.LockPackage)

	for _, pkg := range packages {
		key := packageKey(pkg.Name, pkg.Version)
		packageByKey[key] = pkg
	}

	processed := 0
	for len(queue) > 0 {
		sort.Strings(queue) // Ensure deterministic order
		current := queue[0]
		queue = queue[1:]

		// Add to sorted list
		lockPkg := packageByKey[current]
		sorted = append(sorted, lockPkg)
		sortedKeys[current] = true
		processed++

		// Decrement in-degree of neighbors
		for _, neighbor := range graph[current] {
			if !sortedKeys[neighbor] {
				inDegree[neighbor]--
				if inDegree[neighbor] == 0 {
					queue = append(queue, neighbor)
				}
			}
		}
	}

	// Check for cycles
	if processed != len(packageSet) {
		// Find packages in cycles
		var cyclePackages []string
		for key := range packageSet {
			if !sortedKeys[key] {
				cyclePackages = append(cyclePackages, key)
			}
		}
		return nil, fmt.Errorf("dependency cycle detected involving packages: %v", cyclePackages)
	}

	return sorted, nil
}

// validateDependencyResolution ensures all dependencies exist in the resolved packages
func validateDependencyResolution(packages []*models.LockPackage, packageMap map[string]*models.PackageDefinition) error {
	// Build set of resolved package keys
	resolved := make(map[string]bool)
	for _, pkg := range packages {
		key := packageKey(pkg.Name, pkg.Version)
		resolved[key] = true
	}

	// Check each package''s dependencies
	for _, pkg := range packages {
		// Ensure all dependencies are present in resolved packages
		for _, dep := range pkg.Dependencies {
			// Dependency should be in the format name@version
			if !strings.Contains(dep, "@") {
				return fmt.Errorf("dependency format invalid for package %s: %s (expected name@version)", packageKey(pkg.Name, pkg.Version), dep)
			}
			if !resolved[dep] {
				return fmt.Errorf("dependency not resolved for package %s: %s", packageKey(pkg.Name, pkg.Version), dep)
			}
		}
	}

	return nil
}

// createLockFile creates the lock file structure
func createLockFile(recipe *models.ImageRecipe, packages []*models.LockPackage, recipeHash string) *models.ImageRecipeLock {
	lock := &models.ImageRecipeLock{
		APIVersion: recipe.APIVersion,
		Kind:       "ImageRecipeLock",
		Metadata: models.ImageRecipeLockMetadata{
			Name:        recipe.Metadata.Name,
			Version:     recipe.Metadata.Version,
			LockHash:    recipeHash,
			GeneratedAt: time.Now().UTC().Format(time.RFC3339),
		},
		Target: models.LockTarget{
			Platform:     recipe.Target.Platform,
			Release:      recipe.Target.Release,
			Architecture: recipe.Target.Architecture,
			ImageType:    recipe.Target.ImageType,
		},
		Packages: packages,
		Defaults: models.LockDefaults{
			FailurePolicy: recipe.Defaults.FailurePolicy,
		},
	}

	return lock
}

// writeLockFile writes the lock file to disk
func writeLockFile(path string, lock *models.ImageRecipeLock) error {
	// Ensure output directory exists
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("failed to create output directory: %w", err)
	}

	// Marshal to YAML
	data, err := yaml.Marshal(lock)
	if err != nil {
		return fmt.Errorf("failed to marshal lock file: %w", err)
	}

	// Write to file
	if err := os.WriteFile(path, data, 0644); err != nil {
		return fmt.Errorf("failed to write lock file: %w", err)
	}

	// Write the sidecar install and verify check the lock against
	if err := integrity.WriteSidecar(path); err != nil {
		return fmt.Errorf("failed to write lock sidecar: %w", err)
	}

	return nil
}
