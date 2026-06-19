//go:build !windows

// Stub for non-Windows platforms.
package main

import "fmt"

func isWindowsService() (bool, error) { return false, nil }
func runService() error               { return fmt.Errorf("windows service not supported on this platform") }
func installService() error           { return fmt.Errorf("use systemd or launchd on this platform") }
func uninstallService() error         { return fmt.Errorf("use systemd or launchd on this platform") }
