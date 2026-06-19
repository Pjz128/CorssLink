//go:build windows

// Windows service wrapper for CrossLink Agent.
// Handles SCM lifecycle (install, start, stop, uninstall).
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/eventlog"
	"golang.org/x/sys/windows/svc/mgr"
)

const (
	svcName        = "CrossLinkAgent"
	svcDisplayName = "CrossLink Agent"
	svcDescription = "CrossLink 跨端 AI 代理服务 — 手机远程调用家中电脑的 AI 模型"
)

// isWindowsService reports whether we're running under SCM.
func isWindowsService() (bool, error) {
	return svc.IsWindowsService()
}

// runService blocks and runs the agent as a Windows service.
func runService() error {
	elog, err := eventlog.Open(svcName)
	if err != nil {
		return fmt.Errorf("eventlog open: %w", err)
	}
	defer elog.Close()

	elog.Info(1, fmt.Sprintf("%s starting", svcDisplayName))

	err = svc.Run(svcName, &agentService{elog: elog})
	if err != nil {
		elog.Error(2, fmt.Sprintf("service stopped: %v", err))
		return err
	}
	elog.Info(3, fmt.Sprintf("%s stopped", svcDisplayName))
	return nil
}

type agentService struct {
	elog *eventlog.Log
}

func (s *agentService) Execute(args []string, r <-chan svc.ChangeRequest, changes chan<- svc.Status) (bool, uint32) {
	const cmdsAccepted = svc.AcceptStop | svc.AcceptShutdown

	changes <- svc.Status{State: svc.StartPending}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Start agent in background goroutine
	agentDone := make(chan error, 1)
	go func() {
		agentDone <- runAgent(ctx)
	}()

	changes <- svc.Status{State: svc.Running, Accepts: cmdsAccepted}
	s.elog.Info(4, fmt.Sprintf("%s is running", svcDisplayName))

	// Wait for stop signal or agent crash
	for {
		select {
		case c := <-r:
			switch c.Cmd {
			case svc.Interrogate:
				changes <- c.CurrentStatus
			case svc.Stop, svc.Shutdown:
				s.elog.Info(5, "service stopping...")
				changes <- svc.Status{State: svc.StopPending}
				cancel()
				<-agentDone // wait for agent to finish cleanup
				return false, 0
			default:
				s.elog.Warning(6, fmt.Sprintf("unexpected control: %v", c.Cmd))
			}
		case err := <-agentDone:
			s.elog.Error(7, fmt.Sprintf("agent exited unexpectedly: %v", err))
			changes <- svc.Status{State: svc.Stopped}
			return false, 1
		}
	}
}

// installService registers the agent as a Windows service via SCM.
func installService() error {
	exePath, err := os.Executable()
	if err != nil {
		return fmt.Errorf("cannot find executable: %w", err)
	}

	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("connect to SCM: %w", err)
	}
	defer m.Disconnect()

	s, err := m.OpenService(svcName)
	if err == nil {
		s.Close()
		return fmt.Errorf("service %s already exists — run '%s uninstall' first", svcName, exePath)
	}

	s, err = m.CreateService(svcName, exePath, mgr.Config{
		DisplayName: svcDisplayName,
		Description: svcDescription,
		StartType:   mgr.StartAutomatic, // 开机自启
	}, "")
	if err != nil {
		return fmt.Errorf("create service: %w", err)
	}
	defer s.Close()

	// Set recovery: restart on failure, reset counter after 1 day
	s.SetRecoveryActions([]mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 10 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 30 * time.Second},
	}, 86400)

	fmt.Printf("✅ Service '%s' installed. Starting...\n", svcDisplayName)
	return s.Start()
}

// uninstallService removes the agent from SCM.
func uninstallService() error {
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("connect to SCM: %w", err)
	}
	defer m.Disconnect()

	s, err := m.OpenService(svcName)
	if err != nil {
		return fmt.Errorf("service %s not found: %w", svcName, err)
	}
	defer s.Close()

	// Try to stop first
	s.Control(svc.Stop)

	if err := s.Delete(); err != nil {
		return fmt.Errorf("delete service: %w", err)
	}
	fmt.Printf("✅ Service '%s' uninstalled.\n", svcDisplayName)
	return nil
}

// setupLogging redirects log output for service or interactive mode.
func setupLogging(interactive bool) {
	if interactive {
		log.SetOutput(os.Stdout)
		log.SetFlags(log.Ltime | log.Lmicroseconds)
		return
	}

	// Service mode: log to file
	logDir := filepath.Join(os.Getenv("ProgramData"), "CrossLink")
	os.MkdirAll(logDir, 0755)
	logPath := filepath.Join(logDir, "agent.log")

	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		// Fallback: log to Windows event log only
		log.SetOutput(os.Stderr)
	} else {
		log.SetOutput(f)
	}
	log.SetFlags(log.Ldate | log.Ltime | log.Lmicroseconds)
	log.Printf("=== CrossLink Agent starting (service mode) ===")
}
