//go:build windows

package validators

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"unsafe"

	"golang.org/x/sys/windows"
)

// readVersionInfo reads a file's version resource. FileVersion is the binary
// version from the fixed header, as major.minor.build.revision, because that
// is what an installer's upgrade logic compares; the display string beside it
// is free text. The names come from the first language the resource declares.
func readVersionInfo(path string) (versionInfo, error) {
	var info versionInfo

	size, err := windows.GetFileVersionInfoSize(path, nil)
	if err != nil {
		return info, fmt.Errorf("no version resource: %w", err)
	}
	if size == 0 {
		return info, errors.New("no version resource")
	}
	block := make([]byte, size)
	if err := windows.GetFileVersionInfo(path, 0, size, unsafe.Pointer(&block[0])); err != nil {
		return info, fmt.Errorf("read version resource: %w", err)
	}

	// The version number is read from the resource bytes in the file, not from
	// the block above. For files that belong to Windows, GetFileVersionInfo
	// rewrites the major and minor numbers to the Windows version the calling
	// process is treated as compatible with: a process with no compatibility
	// manifest, like this one, is told 6.2 for a file that says 10.0.
	if version, err := fixedFileVersion(path); err == nil {
		info.FileVersion = version
	} else {
		var fixed *windows.VS_FIXEDFILEINFO
		var fixedLen uint32
		if err := windows.VerQueryValue(unsafe.Pointer(&block[0]), `\`, unsafe.Pointer(&fixed), &fixedLen); err != nil {
			return info, fmt.Errorf("read fixed version info: %w", err)
		}
		if fixed == nil || fixedLen == 0 {
			return info, errors.New("version resource has no fixed version info")
		}
		info.FileVersion = formatFileVersion(fixed.FileVersionMS, fixed.FileVersionLS)
	}

	// US English, Unicode: what most resources use, and the fallback when a
	// resource declares no translation.
	language, codepage := uint16(0x0409), uint16(0x04b0)
	var translation *[2]uint16
	var translationLen uint32
	if err := windows.VerQueryValue(unsafe.Pointer(&block[0]), `\VarFileInfo\Translation`, unsafe.Pointer(&translation), &translationLen); err == nil && translation != nil && translationLen >= 4 {
		language, codepage = translation[0], translation[1]
	}

	info.ProductName = versionString(block, language, codepage, "ProductName")
	info.CompanyName = versionString(block, language, codepage, "CompanyName")
	return info, nil
}

// fixedFileVersion reads the file version straight from the file's version
// resource, by loading the file as data and finding the fixed header in it.
func fixedFileVersion(path string) (string, error) {
	module, err := windows.LoadLibraryEx(path, 0, windows.LOAD_LIBRARY_AS_DATAFILE|windows.LOAD_LIBRARY_AS_IMAGE_RESOURCE)
	if err != nil {
		return "", err
	}
	defer windows.FreeLibrary(module)

	resource, err := windows.FindResource(module, windows.ResourceID(1), windows.RT_VERSION)
	if err != nil {
		return "", err
	}
	data, err := windows.LoadResourceData(module, resource)
	if err != nil {
		return "", err
	}

	// VS_FIXEDFILEINFO starts with the signature 0xFEEF04BD, then the
	// structure version, then the file version as two 32-bit halves.
	signature := []byte{0xBD, 0x04, 0xEF, 0xFE}
	offset := bytes.Index(data, signature)
	if offset < 0 || offset+16 > len(data) {
		return "", errors.New("version resource has no fixed version info")
	}
	return formatFileVersion(
		binary.LittleEndian.Uint32(data[offset+8:]),
		binary.LittleEndian.Uint32(data[offset+12:]),
	), nil
}

func formatFileVersion(ms, ls uint32) string {
	return fmt.Sprintf("%d.%d.%d.%d", ms>>16, ms&0xffff, ls>>16, ls&0xffff)
}

// versionString reads one named string from a version resource, or "" if the
// resource does not have it.
func versionString(block []byte, language, codepage uint16, name string) string {
	subBlock := fmt.Sprintf(`\StringFileInfo\%04x%04x\%s`, language, codepage, name)
	var value *uint16
	var valueLen uint32
	if err := windows.VerQueryValue(unsafe.Pointer(&block[0]), subBlock, unsafe.Pointer(&value), &valueLen); err != nil || value == nil || valueLen == 0 {
		return ""
	}
	return windows.UTF16PtrToString(value)
}
