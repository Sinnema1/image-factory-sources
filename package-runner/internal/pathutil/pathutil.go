package pathutil

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var windowsEnvVarPattern = regexp.MustCompile(`%([A-Za-z_][A-Za-z0-9_]*)%|\$env:[A-Za-z_]([A-Za-z0-9_]*)`)

func ExpandWindowsEnv(path string) string {
	if path == "" {
		return path
	}
	return windowsEnvVarPattern.ReplaceAllStringFunc(path, func(match string) string {
		name := match[1 : len(match)-1]
		if value, ok := os.LookupEnv(name); ok {
			return value
		}
		return match
	})
}

func ResolveUnder(root, path string) (string, error) {
	if path == "" {
		return "", nil
	}
	expanded := ExpandWindowsEnv(path)
	if filepath.IsAbs(expanded) {
		return "", fmt.Errorf("path must be relative, go %q", path)
	}
	resolved := filepath.Join(root, expanded)
	if !strings.HasPrefix(resolved, filepath.Clean(root)+string(filepath.Separator)) {
		return "", fmt.Errorf("path escapes root directory: %q", path)
	}
	return resolved, nil
}
