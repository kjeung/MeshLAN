//go:build windows

package main

import (
	"os/exec"
	"syscall"
)

// hideCommandWindow keeps a helper process from opening a console window of its
// own. The desktop client has no console to inherit, but cmd.exe, PowerShell,
// reg.exe, ping.exe and nebula.exe each create one unless they are told not to,
// and those are the extra black windows users noticed at startup.
func hideCommandWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
}
