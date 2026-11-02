//go:build windows

package main

import (
	"fmt"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"os/exec"
	"syscall"
	"time"
	"unsafe"
)

func hide(c *exec.Cmd) { c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true} }
func openBrowser(u string) {
	c := exec.Command("rundll32.exe", "url.dll,FileProtocolHandler", u)
	hide(c)
	_ = c.Start()
}

type serviceHandler struct {
	run  func() error
	idle func() bool
}

func (h serviceHandler) Execute(_ []string, requests <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}
	done := make(chan error, 1)
	go func() { done <- h.run() }()
	// Refuse administrative stop during deployment; system shutdown relies on the durable checkpoint.
	current := svc.Status{State: svc.Running, Accepts: svc.AcceptShutdown | svc.AcceptStop}
	status <- current
	for {
		select {
		case r := <-requests:
			switch r.Cmd {
			case svc.Interrogate:
				status <- current
			case svc.Stop:
				if !h.idle() {
					status <- current
					continue
				}
				status <- svc.Status{State: svc.StopPending}
				return false, 0
			case svc.Shutdown:
				status <- svc.Status{State: svc.StopPending}
				return false, 0
			}
		case e := <-done:
			if e != nil {
				return false, 1
			}
			return false, 0
		}
	}
}
func serviceRun(run func() error, idle func() bool) (bool, error) {
	is, e := svc.IsWindowsService()
	if e != nil || !is {
		return false, e
	}
	return true, svc.Run("ZYF-CICD-Agent", serviceHandler{run, idle})
}
func runWorker(c *exec.Cmd) error {
	job, e := windows.CreateJobObject(nil, nil)
	if e != nil {
		return e
	}
	defer windows.CloseHandle(job)
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, e = windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info))); e != nil {
		return e
	}
	if e = c.Start(); e != nil {
		return e
	}
	process, e := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(c.Process.Pid))
	if e != nil {
		c.Process.Kill()
		c.Wait()
		return e
	}
	e = windows.AssignProcessToJobObject(job, process)
	windows.CloseHandle(process)
	if e != nil {
		c.Process.Kill()
		c.Wait()
		return e
	}
	done := make(chan error, 1)
	go func() { done <- c.Wait() }()
	select {
	case e := <-done:
		return e
	case <-time.After(100 * time.Minute):
		windows.TerminateJobObject(job, 1)
		<-done
		return fmt.Errorf("task exceeded 100 minute limit; check recovery checkpoint")
	}
}
