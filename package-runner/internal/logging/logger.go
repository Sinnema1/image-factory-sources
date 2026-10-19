// Package logging provides structured logging for package-runner
package logging

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"time"
)

// LogLevel represents the severity level of a log message
type LogLevel string

const (
	LevelDebug LogLevel = "DEBUG"
	LevelInfo  LogLevel = "INFO"
	LevelWarn  LogLevel = "WARN"
	LevelError LogLevel = "ERROR"
	LevelFatal LogLevel = "FATAL"
)

var levelPriorities = map[LogLevel]int{
	LevelDebug: 10,
	LevelInfo:  20,
	LevelWarn:  30,
	LevelError: 40,
	LevelFatal: 50,
}

type Fields map[string]any

// LogEntry represents a structured log entry
type LogEntry struct {
	Timestamp   time.Time `json:"timestamp"`
	Level       LogLevel  `json:"level"`
	Message     string    `json:"message"`
	ExecutionID string    `json:"executionId,omitempty"`
	Fields      Fields    `json:"fields,omitempty"`
}

type Handler interface {
	Handle(entry LogEntry) error
}

type Logger struct {
	mu          sync.RWMutex
	minLevel    LogLevel
	fields      Fields
	executionID string
	handlers    []Handler
	now         func() time.Time
	exit        func(int)
}

func NewLogger(minLevel LogLevel, handlers ...Handler) *Logger {
	if !minLevel.IsValid() {
		minLevel = LevelInfo
	}

	return &Logger{
		minLevel: minLevel,
		fields:   make(Fields),
		handlers: compactHandlers(handlers),
		now:      time.Now,
		exit:     os.Exit,
	}
}

func NewDefaultLogger() *Logger {
	return NewLogger(
		LevelInfo,
		NewConsoleHandler(os.Stderr, ConsoleOptions{
			ColorEnabled:     SupportsColor(os.Stderr),
			IncludeTimestamp: true,
		}),
	)
}

func NewJSONLogger(output io.Writer, minLevel LogLevel) *Logger {
	if output == nil {
		output = os.Stderr
	}
	return NewLogger(minLevel, NewJSONHandler(output))
}

func (level LogLevel) IsValid() bool {
	_, exists := levelPriorities[level]
	return exists
}

func (logger *Logger) Enabled(level LogLevel) bool {
	if logger == nil || !level.IsValid() {
		return false
	}
	logger.mu.RLock()
	minLevel := logger.minLevel
	logger.mu.RUnlock()
	return compareLevel(level, minLevel) >= 0
}

func (logger *Logger) Log(level LogLevel, message string, additionalFields Fields) error {
	if logger == nil {
		return nil
	}
	if !level.IsValid() {
		return fmt.Errorf("invalid log level %q", level)
	}
	if !logger.Enabled(level) {
		return nil
	}

	logger.mu.RLock()
	// Create log entry
	entry := LogEntry{
		Timestamp:   time.Now().UTC(),
		Level:       level,
		Message:     message,
		ExecutionID: logger.executionID,
		Fields:      mergeFields(logger.fields, additionalFields),
	}
	handlers := append([]Handler(nil), logger.handlers...)
	logger.mu.RUnlock()

	var handlerErrors []error
	for _, handler := range handlers {
		if err := handler.Handle(entry); err != nil {
			handlerErrors = append(handlerErrors, fmt.Errorf("write %s log entry using %T: %w", level, handler, err))
		}
	}
	return errors.Join(handlerErrors...)
}

func (logger *Logger) Debug(message string, fields ...Fields) {
	_ = logger.Log(LevelDebug, message, firstFields(fields))
}
func (logger *Logger) Info(message string, fields ...Fields) {
	_ = logger.Log(LevelInfo, message, firstFields(fields))
}
func (logger *Logger) Warn(message string, fields ...Fields) {
	_ = logger.Log(LevelWarn, message, firstFields(fields))
}
func (logger *Logger) Error(message string, fields ...Fields) {
	_ = logger.Log(LevelError, message, firstFields(fields))
}
func (logger *Logger) Fatal(message string, fields ...Fields) {
	if logger == nil {
		os.Exit(1)
		return
	}
	_ = logger.Log(LevelFatal, message, firstFields(fields))
	logger.mu.RLock()
	exit := logger.exit
	logger.mu.RUnlock()
	exit(1)
}
func (logger *Logger) Panic(message string, fields ...Fields) {
	_ = logger.Log(LevelFatal, message, firstFields(fields))
	panic(message)
}

func (logger *Logger) WithFields(fields Fields) *Logger {
	if logger == nil {
		return NewLogger(LevelInfo)
	}
	logger.mu.RLock()
	defer logger.mu.RUnlock()
	return &Logger{
		minLevel:    logger.minLevel,
		fields:      mergeFields(logger.fields, fields),
		executionID: logger.executionID,
		handlers:    append([]Handler(nil), logger.handlers...),
		now:         logger.now,
		exit:        logger.exit,
	}
}

func (logger *Logger) WithExecutionID(id string) *Logger {
	child := logger.WithFields(nil)
	child.executionID = strings.TrimSpace(id)
	return child
}

func (logger *Logger) SetMinLevel(level LogLevel) {
	if logger == nil || !level.IsValid() {
		return
	}
	logger.mu.Lock()
	logger.minLevel = level
	logger.mu.Unlock()
}

func (logger *Logger) SetHandlers(handlers ...Handler) {
	if logger == nil {
		return
	}
	logger.mu.Lock()
	logger.handlers = compactHandlers(handlers)
	logger.mu.Unlock()
}

func (logger *Logger) AddHandler(handler Handler) {
	if logger == nil || handler == nil {
		return
	}
	logger.mu.Lock()
	logger.handlers = append(logger.handlers, handler)
	logger.mu.Unlock()
}

func (logger *Logger) SetOutput(output io.Writer) {
	if logger == nil || output == nil {
		return
	}
	logger.SetHandlers(NewJSONHandler(output))
}

func (logger *Logger) Close() error { return nil }

func compareLevel(left, right LogLevel) int {
	return levelPriorities[left] - levelPriorities[right]
}

func firstFields(values []Fields) Fields {
	if len(values) == 0 {
		return nil
	}
	return values[0]
}

func compactHandlers(handlers []Handler) []Handler {
	result := make([]Handler, 0, len(handlers))
	for _, handler := range handlers {
		if handler != nil {
			result = append(result, handler)
		}
	}
	return result
}

func cloneFields(source Fields) Fields {
	if len(source) == 0 {
		return nil
	}
	result := make(Fields, len(source))
	for key, value := range source {
		result[key] = value
	}
	return result
}

func mergeFields(base, additional Fields) Fields {
	if len(base) == 0 {
		return cloneFields(additional)
	}
	if len(additional) == 0 {
		return cloneFields(base)
	}
	result := make(Fields, len(base)+len(additional))
	for key, value := range base {
		result[key] = value
	}
	for key, value := range additional {
		result[key] = value
	}
	return result
}

type JSONHandler struct {
	mu     sync.Mutex
	writer io.Writer
}

func NewJSONHandler(writer io.Writer) *JSONHandler {
	return &JSONHandler{writer: writer}
}

func (handler *JSONHandler) Handle(entry LogEntry) error {
	if handler == nil || handler.writer == nil {
		return nil
	}
	handler.mu.Lock()
	defer handler.mu.Unlock()
	encoder := json.NewEncoder(handler.writer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(entry); err != nil {
		return fmt.Errorf("encode JSON log entry: %w", err)
	}
	return nil
}
