// Package main provides the entry point for package-runner CLI
package main

import (
	"flag"
	"fmt"
	"os"

	"package-runner/internal/cli"
)

// Build version information (injected by build system)
var (
	Version = "dev"
	Commit  = "unknown"
	Date    = "unknown"
)

func main() {
	// Set up basic flag parsing for help
	helpFlag := flag.Bool("help", false, "Show help information")
	versionFlag := flag.Bool("version", false, "Show version information")

	// Parse flags
	flag.Parse()

	// Handle help and version flags
	if *helpFlag || *versionFlag || len(flag.Args()) == 0 {
		if *versionFlag {
			printVersion()
			return
		}
		printUsage()
		if *helpFlag {
			return
		}
		os.Exit(1)
	}

	// Handle CLI commands
	cli.Version = Version
	cli.Commit = Commit
	cli.Date = Date

	if err := cli.Run(flag.Args()); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func printUsage() {
	usage := `
Package Runner - A tool for executing approved software installation handlers during VM image builds

Usage:
  package-runner.exe <command> [options]

Commands:
  version              Show version information
  handlers             Show supported handler types
  resolve              Resolve package dependencies and create lock file
  validate             Validate a lock file
  install              Execute installation from a lock file
  install-package      Install a specific package from a lock file
  detect               Detect package information from definition

Use "package-runner.exe <command> --help" for more information about a command.

Examples:
  package-runner.exe version
  package-runner.exe handlers
  package-runner.exe resolve --recipe .\recipes\windows-vm.recipe.yaml --output .\out\windows-vm.recipe.lock.yaml
  package-runner.exe validate --lock .\out\windows-vm.recipe.lock.yaml --verify-artifacts
  package-runner.exe install --lock .\out\windows-vm.recipe.lock.yaml --evidence-dir .\out\evidence --execution-id 123456
`
	fmt.Fprintf(os.Stderr, usage)
}

func printVersion() {
	fmt.Printf("package-runner version %s\n", Version)
	fmt.Printf("commit: %s\n", Commit)
	fmt.Printf("built at: %s\n", Date)
}
