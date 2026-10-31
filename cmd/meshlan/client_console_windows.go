//go:build windows

package main

import (
	"os"
	"os/exec"
	"unsafe"

	"golang.org/x/sys/windows"
)

// A windowsgui binary has no console of its own, but cmd.exe, a shortcut or an
// update helper can still attach one: that is the second black window users
// saw next to the desktop UI. detachOwnConsole drops the console this process
// inherited; hideCommandWindow (exec_window_windows.go) keeps every spawned
// helper from opening one of its own.
const clientShowWindowHide = 0

var (
	clientKernel32         = windows.NewLazySystemDLL("kernel32.dll")
	clientUser32           = windows.NewLazySystemDLL("user32.dll")
	clientShowWindowProc   = clientUser32.NewProc("ShowWindow")
	clientGetConsoleWindow = clientKernel32.NewProc("GetConsoleWindow")
	clientFreeConsole      = clientKernel32.NewProc("FreeConsole")
	clientConsoleProcesses = clientKernel32.NewProc("GetConsoleProcessList")
)

// detachOwnConsole hides and frees the console this process owns. When another
// process — typically the cmd.exe window the user launched from — shares the
// console, it is left alone: that window belongs to the user's shell, not to
// MeshLAN, and closing it would kill the shell too.
func detachOwnConsole() {
	console, _, _ := clientGetConsoleWindow.Call()
	if console == 0 {
		return
	}
	if !ownsConsoleAlone() {
		return
	}
	_, _, _ = clientShowWindowProc.Call(console, clientShowWindowHide)
	_, _, _ = clientFreeConsole.Call()
}

func ownsConsoleAlone() bool {
	ids := make([]uint32, 64)
	returned, _, _ := clientConsoleProcesses.Call(uintptr(unsafe.Pointer(&ids[0])), uintptr(len(ids)))
	if returned == 0 {
		// The list call fails when no console is attached; if one is, it is not
		// ours to close.
		console, _, _ := clientGetConsoleWindow.Call()
		return console == 0
	}
	current := windows.GetCurrentProcessId()
	for _, pid := range ids[:returned] {
		if pid != 0 && pid != current {
			return false
		}
	}
	return true
}

// openClientLogForSupport hands the diagnostic bundle the tail of the client
// log so a user can report a problem without hunting through %APPDATA%.
func openClientLogForSupport(redactor *diagnosticRedactor) ([]byte, string, error) {
	data, path, err := clientLogSnapshot(logSnapshotLimitBytes)
	if err != nil {
		return nil, path, err
	}
	if redactor != nil {
		data = []byte(redactor.Text(string(data)))
	}
	return data, path, nil
}

// revealClientLog opens the log in Notepad: the Windows habit for "show me the
// file behind this problem" without adding a second viewer to the client.
func revealClientLog() error {
	path := clientLogCurrentPath()
	if path == "" {
		return os.ErrNotExist
	}
	command := exec.Command("notepad.exe", path)
	hideCommandWindow(command)
	return command.Start()
}
