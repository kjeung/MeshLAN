package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// The Windows desktop client is linked with -H=windowsgui, so Windows never
// hands it a console: everything the client printed to stdout/stderr was
// dropped on the floor. The client also picks up a stray console whenever a
// shell launches it, which is the second window users saw at startup.
//
// This file owns the file half of that fix and is deliberately platform
// neutral so the rotation rules can be tested anywhere:
//
//	%APPDATA%\MeshLANNebula\client\logs\meshlan-client.log
//
// The active file is capped at clientLogMaxBytes and keeps
// clientLogBackupCount older generations (meshlan-client.log.1, .2), so a
// client left running for months cannot fill the disk.
const (
	clientLogDirectoryName  = "logs"
	clientLogFileName       = "meshlan-client.log"
	clientLogMaxBytes       = 2 << 20
	clientLogBackupCount    = 2
	clientLogRotationPeriod = 15 * time.Second
	logSnapshotLimitBytes   = 4 << 20
)

type clientLogRotationSettings struct {
	Directory  string `json:"directory"`
	Filename   string `json:"filename"`
	MaxBytes   int64  `json:"maxBytes"`
	MaxBackups int    `json:"maxBackups"`
	Console    string `json:"console"`
	Configured bool   `json:"configured"`
	Source     string `json:"source,omitempty"`
	LastError  string `json:"lastError,omitempty"`
}

type clientLogState struct {
	mu         sync.Mutex
	file       *os.File
	path       string
	directory  string
	maxBytes   int64
	maxBackups int
	source     string
	lastError  error
	stop       chan struct{}
	stopOnce   sync.Once
}

var clientLog struct {
	stateMu sync.Mutex
	current *clientLogState
}

func clientLogRotationDefaults(root string) clientLogRotationSettings {
	return clientLogRotationSettings{
		Directory:  filepath.Join(root, clientLogDirectoryName),
		Filename:   clientLogFileName,
		MaxBytes:   clientLogMaxBytes,
		MaxBackups: clientLogBackupCount,
		Console:    "file",
		Configured: true,
		Source:     "default",
	}
}

// clientLogRotationTarget resolves where the client log lives. An operator can
// overrule the defaults in <state root>/log-rotation.json; the client reads
// that file but never rewrites it, so a deployment can pin its own path.
func clientLogRotationTarget(root string) (clientLogRotationSettings, error) {
	settings := clientLogRotationDefaults(root)
	if strings.TrimSpace(root) == "" {
		return settings, nil
	}
	data, err := os.ReadFile(filepath.Join(root, "log-rotation.json"))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return settings, nil
		}
		return settings, err
	}
	var stored clientLogRotationSettings
	if err := json.Unmarshal(data, &stored); err != nil {
		return settings, err
	}
	if directory := strings.TrimSpace(stored.Directory); directory != "" {
		settings.Directory = filepath.Clean(directory)
	}
	if name := strings.TrimSpace(stored.Filename); name != "" {
		settings.Filename = name
	}
	if stored.MaxBytes > 0 {
		settings.MaxBytes = stored.MaxBytes
	}
	if stored.MaxBackups > 0 {
		settings.MaxBackups = stored.MaxBackups
	}
	settings.Source = "config"
	return settings, nil
}

func maxClientLogBytes(settings clientLogRotationSettings) int64 {
	if settings.MaxBytes > 0 {
		return settings.MaxBytes
	}
	return clientLogMaxBytes
}

func clientLogBackups(settings clientLogRotationSettings) int {
	if settings.MaxBackups > 0 {
		return settings.MaxBackups
	}
	return clientLogBackupCount
}

// initClientLog opens the rotating log and hands the process streams to it.
// A failure is recorded in the status payload instead of aborting startup: a
// read-only profile must still get its desktop window.
func initClientLog(root string) clientLogRotationSettings {
	settings, err := clientLogRotationTarget(root)
	if err != nil {
		settings = clientLogRotationDefaults(root)
		settings.LastError = err.Error()
	}
	state, openErr := openClientLog(settings)
	if openErr != nil {
		if settings.LastError == "" {
			settings.LastError = openErr.Error()
		}
		return settings
	}
	clientLog.stateMu.Lock()
	previous := clientLog.current
	clientLog.current = state
	clientLog.stateMu.Unlock()
	if previous != nil {
		previous.close()
	}
	return clientLogRotationStatus(root)
}

func clientLogRotationStatus(root string) clientLogRotationSettings {
	settings, err := clientLogRotationTarget(root)
	clientLog.stateMu.Lock()
	current := clientLog.current
	clientLog.stateMu.Unlock()
	if current == nil {
		if err != nil && settings.LastError == "" {
			settings.LastError = err.Error()
		}
		return settings
	}
	current.mu.Lock()
	defer current.mu.Unlock()
	settings.Directory = current.directory
	settings.Filename = filepath.Base(current.path)
	settings.MaxBytes = current.maxBytes
	settings.MaxBackups = current.maxBackups
	settings.Source = current.source
	settings.Console = "file"
	settings.Configured = true
	if current.lastError != nil {
		settings.LastError = current.lastError.Error()
	}
	return settings
}

func clientLogCurrentPath() string {
	clientLog.stateMu.Lock()
	current := clientLog.current
	clientLog.stateMu.Unlock()
	if current == nil {
		return ""
	}
	current.mu.Lock()
	defer current.mu.Unlock()
	return current.path
}

// setClientLogDirectory moves the log elsewhere at runtime, keeping the same
// size rules.
func setClientLogDirectory(root, directory string) error {
	settings, err := clientLogRotationTarget(root)
	if err != nil {
		return err
	}
	directory = strings.TrimSpace(directory)
	if directory == "" {
		return errors.New("日志目录不能为空")
	}
	settings.Directory = filepath.Clean(directory)
	settings.Source = "manual"
	state, openErr := openClientLog(settings)
	if openErr != nil {
		return openErr
	}
	clientLog.stateMu.Lock()
	previous := clientLog.current
	clientLog.current = state
	clientLog.stateMu.Unlock()
	if previous != nil {
		previous.close()
	}
	return nil
}

func openClientLog(settings clientLogRotationSettings) (*clientLogState, error) {
	directory := settings.Directory
	if strings.TrimSpace(directory) == "" {
		return nil, errors.New("日志目录无效")
	}
	name := settings.Filename
	if strings.TrimSpace(name) == "" {
		name = clientLogFileName
	}
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return nil, err
	}
	state := &clientLogState{
		path:       filepath.Join(directory, name),
		directory:  directory,
		maxBytes:   maxClientLogBytes(settings),
		maxBackups: clientLogBackups(settings),
		source:     settings.Source,
		stop:       make(chan struct{}),
	}
	if err := state.reopen(); err != nil {
		return nil, err
	}
	// A windowsgui binary has no console of its own, so the client's own output
	// — fmt prints, the standard logger, and main's error lines — goes to the
	// rotating file instead of disappearing.
	state.redirectStreams()
	state.writeHeader()
	go state.rotationLoop()
	return state, nil
}

// redirectStreams points the process streams at the active file. The caller
// holds s.mu.
func (s *clientLogState) redirectStreamsLocked() {
	if s.file == nil {
		return
	}
	os.Stdout, os.Stderr = s.file, s.file
	log.SetOutput(s.file)
}

func (s *clientLogState) redirectStreams() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.redirectStreamsLocked()
}

func (s *clientLogState) openFile() *os.File {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.file
}

func (s *clientLogState) writeHeader() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.file == nil {
		return
	}
	_, _ = fmt.Fprintf(s.file, "%s MeshLAN Nebula %s 启动 (pid %d)；日志轮转 %s，保留 %d 份\n",
		time.Now().Format(time.RFC3339), clientVersionNumber(), os.Getpid(), humanBytes(s.maxBytes), s.maxBackups)
}

func humanBytes(value int64) string {
	if value >= 1<<20 {
		return fmt.Sprintf("%d MB", value/(1<<20))
	}
	if value >= 1<<10 {
		return fmt.Sprintf("%d KB", value/(1<<10))
	}
	return fmt.Sprintf("%d B", value)
}

// reopen rotates first when the file inherited from an earlier run is already
// oversized, then opens it in append mode so a restart does not truncate the
// evidence the user may be about to send in a diagnostic bundle.
func (s *clientLogState) reopen() error {
	if info, err := os.Stat(s.path); err == nil && info.Size() >= s.maxBytes {
		if rotateErr := rotateClientLogFile(s.path, s.maxBackups); rotateErr != nil {
			return rotateErr
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.reopenLocked()
}

func (s *clientLogState) reopenLocked() error {
	file, err := os.OpenFile(s.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		s.lastError = err
		return err
	}
	s.file = file
	return nil
}

func (s *clientLogState) rotationLoop() {
	ticker := time.NewTicker(clientLogRotationPeriod)
	defer ticker.Stop()
	for {
		select {
		case <-s.stop:
			return
		case <-ticker.C:
			s.rotateIfNeeded()
		}
	}
}

// rotateIfNeeded swaps the streams onto a fresh file in one step, so output
// never keeps appending into an already-renamed generation.
func (s *clientLogState) rotateIfNeeded() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.file == nil {
		return
	}
	info, err := s.file.Stat()
	if err != nil || info.Size() < s.maxBytes {
		return
	}
	_ = s.file.Close()
	s.file = nil
	if rotateErr := rotateClientLogFile(s.path, s.maxBackups); rotateErr != nil {
		s.lastError = rotateErr
	}
	if err := s.reopenLocked(); err != nil {
		return
	}
	s.redirectStreamsLocked()
}

func (s *clientLogState) close() {
	s.stopOnce.Do(func() { close(s.stop) })
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.file != nil {
		_ = s.file.Close()
		s.file = nil
	}
}

// rotateClientLogFile shifts name -> name.1 -> name.2 … and drops the oldest
// generation. Rename failures are tolerated: on Windows an outside reader may
// hold an old generation open, and losing one generation beats losing the log.
func rotateClientLogFile(path string, maxBackups int) error {
	if maxBackups < 1 {
		return os.Remove(path)
	}
	var lastErr error
	_ = os.Remove(clientLogBackupName(path, maxBackups))
	for index := maxBackups - 1; index >= 1; index-- {
		if err := os.Rename(clientLogBackupName(path, index), clientLogBackupName(path, index+1)); err != nil && !errors.Is(err, os.ErrNotExist) {
			lastErr = err
		}
	}
	if err := os.Rename(path, clientLogBackupName(path, 1)); err != nil && !errors.Is(err, os.ErrNotExist) {
		lastErr = err
	}
	return lastErr
}

func clientLogBackupName(path string, index int) string {
	return fmt.Sprintf("%s.%d", path, index)
}

// clientLogSnapshot reads the tail of the active log for the diagnostic bundle,
// bounded so a support report never balloons.
func clientLogSnapshot(limit int64) ([]byte, string, error) {
	path := clientLogCurrentPath()
	if path == "" {
		return nil, "", errors.New("日志文件尚未初始化")
	}
	if limit <= 0 || limit > logSnapshotLimitBytes {
		limit = logSnapshotLimitBytes
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, path, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, path, err
	}
	if offset := info.Size() - limit; offset > 0 {
		if _, err := file.Seek(offset, io.SeekStart); err != nil {
			return nil, path, err
		}
	}
	data := make([]byte, 0, limit)
	buffer := make([]byte, 64<<10)
	for int64(len(data)) < limit {
		n, readErr := file.Read(buffer)
		data = append(data, buffer[:n]...)
		if readErr != nil || n == 0 {
			break
		}
	}
	return data, path, nil
}
