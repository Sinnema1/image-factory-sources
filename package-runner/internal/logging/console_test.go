package logging

import (
	"bytes"
	"strings"
	"testing"
)

type consoleCheck struct {
	Name   string `json:"name"`
	Passed bool   `json:"passed"`
}

func TestConsoleWritesStructuredFieldsAsJSON(t *testing.T) {
	var output bytes.Buffer
	logger := NewLogger(LevelInfo, NewConsoleHandler(&output, ConsoleOptions{}))
	logger.Info("Validation PASSED", Fields{
		"checks": []consoleCheck{{Name: "exists", Passed: true}},
		"target": `C:\Program Files\App\app.exe`,
		"count":  2,
	})

	line := output.String()
	for _, want := range []string{
		`checks=[{"name":"exists","passed":true}]`,
		`target="C:\\Program Files\\App\\app.exe"`,
		`count=2`,
	} {
		if !strings.Contains(line, want) {
			t.Errorf("console line is missing %s\n%s", want, line)
		}
	}
	if strings.Contains(line, "map[") || strings.Contains(line, "{exists true}") {
		t.Errorf("structured field printed in Go syntax:\n%s", line)
	}
}
