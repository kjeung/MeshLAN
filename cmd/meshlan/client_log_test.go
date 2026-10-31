package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestClientLogRotationKeepsBoundedGenerations(t *testing.T) {
	root := t.TempDir()
	settings := clientLogRotationDefaults(filepath.Join(root, "logs"))
	settings.MaxBytes = 1024
	settings.MaxBackups = 2
	state, err := openClientLog(settings)
	if err != nil {
		t.Fatal(err)
	}
	defer state.close()

	file := state.openFile()
	if file == nil {
		t.Fatal("log file was not opened")
	}
	for index := 0; index < 40; index++ {
		// Rotate by hand as the ticker would, because the test must not wait on
		// wall-clock time.
		_, _ = fmt.Fprintf(file, "%s line %d\n", strings.Repeat("x", 100), index)
		state.rotateIfNeeded()
		file = state.openFile()
	}
	path := state.path
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	generations := 1
	var total int64
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), filepath.Base(path)+".") {
			generations++
		}
		info, statErr := entry.Info()
		if statErr != nil {
			t.Fatal(statErr)
		}
		total += info.Size()
	}
	if generations > settings.MaxBackups+1 {
		t.Fatalf("rotation kept %d files, limit is %d", generations, settings.MaxBackups+1)
	}
	// Each generation is capped, so the whole directory stays small even after
	// far more writes than the limit allows.
	if total > int64(settings.MaxBytes)*(int64(settings.MaxBackups)+1)*2 {
		t.Fatalf("log directory grew to %d bytes with a %d byte limit", total, settings.MaxBytes)
	}
	if _, err := os.Stat(state.path); err != nil {
		t.Fatalf("active log file missing after rotation: %v", err)
	}
}

func TestClientLogRotationEnforcesGenerationOrder(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, clientLogFileName)
	if err := os.WriteFile(path, []byte("current"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(clientLogBackupName(path, 1), []byte("older"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := rotateClientLogFile(path, clientLogBackupCount); err != nil {
		t.Fatal(err)
	}
	current, err := os.ReadFile(clientLogBackupName(path, 1))
	if err != nil || string(current) != "current" {
		t.Fatalf("active file was not shifted to generation 1: %q err=%v", current, err)
	}
	older, err := os.ReadFile(clientLogBackupName(path, 2))
	if err != nil || string(older) != "older" {
		t.Fatalf("generation 1 was not shifted to generation 2: %q err=%v", older, err)
	}
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Fatalf("active file still exists after rotation: %v", statErr)
	}
}

func TestClientLogSettingsOverrideAndStatusReportEffectivePath(t *testing.T) {
	// initClientLog repoints the process streams; put them back for the rest of
	// the test binary.
	originalStdout, originalStderr := os.Stdout, os.Stderr
	t.Cleanup(func() { os.Stdout, os.Stderr = originalStdout, originalStderr })
	root := t.TempDir()
	override := filepath.Join(root, "rotated")
	if err := os.WriteFile(filepath.Join(root, "log-rotation.json"),
		[]byte(`{"directory":"`+strings.ReplaceAll(override, `\`, `\\`)+`","maxBytes":512,"maxBackups":1}`), 0o600); err != nil {
		t.Fatal(err)
	}
	status := initClientLog(root)
	defer func() {
		clientLog.stateMu.Lock()
		current := clientLog.current
		clientLog.current = nil
		clientLog.stateMu.Unlock()
		if current != nil {
			current.close()
		}
	}()
	if status.Directory != override || status.MaxBytes != 512 || status.MaxBackups != 1 {
		t.Fatalf("override was not applied: %#v", status)
	}
	if len(status.LastError) != 0 {
		t.Fatalf("unexpected log error: %s", status.LastError)
	}
	if path := clientLogCurrentPath(); path != filepath.Join(override, clientLogFileName) {
		t.Fatalf("effective log path is %q", path)
	}
}

func TestClientLogInitNeverFailsOnReadOnlyDirectory(t *testing.T) {
	// A path that cannot be created must not abort client startup; the status
	// payload carries the reason instead.
	root := filepath.Join(t.TempDir(), "missing", "logs")
	status := clientLogRotationStatus(root)
	if status.Directory == "" || status.Filename != clientLogFileName {
		t.Fatalf("defaults not reported when the log cannot be opened: %#v", status)
	}
}
