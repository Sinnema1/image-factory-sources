package logging

import (
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
)

const (
	ansiReset        = "\x1b[0m"
	ansiBold         = "\x1b[1m"
	ansiDim          = "\x1b[2m"
	ansiRed          = "\x1b[31m"
	ansiGreen        = "\x1b[32m"
	ansiYellow       = "\x1b[33m"
	ansiBlue         = "\x1b[34m"
	ansiMagenta      = "\x1b[35m"
	ansiCyan         = "\x1b[36m"
	ansiBrightRed    = "\x1b[91m"
	ansiBrightYellow = "\x1b[93m"
)

// ConsoleOptions controls human-readable console formatting
type ConsoleOptions struct {
	ColorEnabled     bool
	IncludeTimestamp bool
}

type ConsoleHandler struct {
	mu      sync.Mutex
	writer  io.Writer
	options ConsoleOptions
}

func NewConsoleHandler(writer io.Writer, options ConsoleOptions) *ConsoleHandler {
	return &ConsoleHandler{writer: writer, options: options}
}

func (handler *ConsoleHandler) Handle(entry LogEntry) error {
	if handler == nil || handler.writer == nil {
		return nil
	}
	line := handler.format(entry)
	handler.mu.Lock()
	defer handler.mu.Unlock()
	if _, err := fmt.Fprintln(handler.writer, line); err != nil {
		return fmt.Errorf("write console log entry: %w", err)
	}
	return nil
}

func (handler *ConsoleHandler) format(entry LogEntry) string {
	var builder strings.Builder
	if handler.options.IncludeTimestamp {
		builder.WriteString(handler.style(ansiDim, entry.Timestamp.Format("2026-01-02T15:04:05.000Z")))
		builder.WriteByte(' ')
	}
	builder.WriteString(handler.levelLabel(entry.Level))
	builder.WriteByte(' ')
	builder.WriteString(sanitizeConsoleMessge(entry.Message))
	if entry.ExecutionID != "" {
		builder.WriteByte(' ')
		builder.WriteString(handler.style(ansiDim, "executionId="+quoteConsoleValue(entry.ExecutionID)))
	}
	if formattedFields := handler.formatFields(entry.Fields); formattedFields != "" {
		builder.WriteByte(' ')
		builder.WriteString(formattedFields)
	}
	return builder.String()

}

func (handler *ConsoleHandler) levelLabel(level LogLevel) string {
	color := ansiMagenta
	switch level {
	case LevelDebug:
		color = ansiCyan
	case LevelInfo:
		color = ansiGreen
	case LevelWarn:
		color = ansiBrightYellow
	case LevelError:
		color = ansiRed
	case LevelFatal:
		color = ansiBrightRed
	}
	return handler.style(color+ansiBold, "["+string(level)+"]")
}

func (handler *ConsoleHandler) formatFields(fields map[string]interface{}) string {
	if len(fields) == 0 {
		return ""
	}
	keys := make([]string, 0, len(fields))
	for key := range fields {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		parts = append(parts, key+"="+quoteConsoleValue(fmt.Sprint(fields[key])))
	}
	return handler.style(ansiDim, strings.Join(parts, " "))

}

func (handler *ConsoleHandler) style(style, value string) string {
	if !handler.options.ColorEnabled {
		return value
	}
	return style + value + ansiReset

}

func SupportsColor(writer io.Writer) bool {
	if os.Getenv("NO_COLOR") != "" || strings.EqualFold(os.Getenv("TERM"), "dumb") {
		return false
	}
	if strings.EqualFold(os.Getenv("CI"), "true") {
		return true
	}
	file, ok := writer.(*os.File)
	if !ok {
		return false
	}
	info, err := file.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

func sanitizeConsoleMessge(message string) string {
	replacer := strings.NewReplacer("\r\n", " ", "\r", " ", "\n", " ")
	return replacer.Replace((message))
}

func quoteConsoleValue(value string) string {
	if value == "" || strings.ContainsAny(value, " \t\r\n=\"") {
		return strconv.Quote(value)
	}
	return value
}
