//go:build !windows

package main

import "os/exec"

// hideCommandWindow is a no-op outside Windows, where helpers keep the terminal
// the operator launched them from.
func hideCommandWindow(*exec.Cmd) {}
