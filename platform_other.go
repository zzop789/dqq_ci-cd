//go:build !windows

package main

import "os/exec"

func hide(c *exec.Cmd)                                            {}
func openBrowser(u string)                                        {}
func serviceRun(run func() error, idle func() bool) (bool, error) { return false, nil }
func runWorker(c *exec.Cmd) error                                 { return c.Run() }
