package main

import (
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// The legacy JSON configuration is reported read-only as well. Deployments no
// longer write it: the package owns gameplay and economy configuration, and
// the executable server keeps its own values. The manager supplies no
// replacement values and never invokes the game program to validate a
// candidate it would have been about to write.
func serverConfigPath(root string) (string, error) {
	selected := strings.TrimSpace(os.Getenv("SERVER_CONFIG_FILE"))
	if selected == "" {
		b, e := os.ReadFile(filepath.Join(root, "shared", ".env"))
		if e != nil && !os.IsNotExist(e) {
			return "", e
		}
		for _, line := range strings.Split(string(b), "\n") {
			k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
			if ok && strings.TrimSpace(k) == "SERVER_CONFIG_FILE" {
				selected = strings.Trim(strings.TrimSpace(v), "\"'")
			}
		}
	}
	if selected != "" {
		if !filepath.IsAbs(selected) {
			return "", errors.New("SERVER_CONFIG_FILE 必须为绝对路径")
		}
		return filepath.Clean(selected), nil
	}
	return filepath.Join(root, "shared", "server.json"), nil
}

func (a *App) serverConfig(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	defer a.mu.Unlock()
	path, e := serverConfigPath(a.cfg.InstallRoot)
	if e != nil {
		fail(w, e)
		return
	}
	b, e := os.ReadFile(path)
	exists := e == nil
	if e != nil && !os.IsNotExist(e) {
		fail(w, e)
		return
	}
	revision := "missing"
	if exists {
		revision = envRevision(b)
	}
	if r.Method != "GET" {
		fail(w, errors.New("玩法配置为只读诊断：配置由部署包提供并在每次部署时整体替换，网页不再提供保存入口"))
		return
	}
	respond(w, 200, map[string]any{
		"read_only": true,
		"policy":    "release_owned",
		"path":      path,
		"exists":    exists,
		"text":      string(b),
		"revision":  revision,
	})
}
