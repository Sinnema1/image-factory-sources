//go:build !windows

package validators

import (
	"fmt"
)

// readVersionInfo reads a file's version resource. FileVersion is the binary
// version from the fixed header, as major.minor.build.revision, because that
// is what an installer's upgrade logic compares; the display string beside it
// is free text. The names come from the first language the resource declares.
func readVersionInfo(path string) (versionInfo, error) {

	return versionInfo{}, fmt.Errorf("this CLI command can only be run on windows OS")
}

// fixedFileVersion reads the file version straight from the file's version
// resource, by loading the file as data and finding the fixed header in it.
func fixedFileVersion(path string) (string, error) {

	return "", fmt.Errorf("this CLI command can only be run on windows OS")

}

func formatFileVersion(ms, ls uint32) string {
	return fmt.Sprintf("%d.%d.%d.%d", ms>>16, ms&0xffff, ls>>16, ls&0xffff)
}
