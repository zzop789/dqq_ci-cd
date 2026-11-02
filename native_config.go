package main

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// File diagnostics only. Gameplay authority depends on the configured source;
// host lifecycle policies have a separate draft/maintenance editing endpoint.
var nativeConfigNames = []string{"host.json", "gameplay.lua", "economy.lua"}

func readNativeFiles(dir string) (map[string]string, string, error) {
	files := map[string]string{}
	var revision strings.Builder
	for _, name := range nativeConfigNames {
		p := filepath.Join(dir, name)
		info, e := os.Lstat(p)
		if e != nil {
			return nil, "", e
		}
		if !info.Mode().IsRegular() || info.Size() > 1<<20 {
			return nil, "", fmt.Errorf("%s 必须是小于1MiB的普通文件", name)
		}
		b, e := os.ReadFile(p)
		if e != nil {
			return nil, "", e
		}
		files[name] = string(b)
		revision.WriteString(name + ":" + envRevision(b) + "\n")
	}
	return files, envRevision([]byte(revision.String())), nil
}

// nativeConfig serves a read-only view of the live native configuration files.
// Writes are rejected here; ordinary deployment preserves shared files.
func (a *App) nativeConfig(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	defer a.mu.Unlock()
	dir := filepath.Join(a.cfg.InstallRoot, "shared")
	files, revision, e := readNativeFiles(dir)
	if e != nil {
		fail(w, fmt.Errorf("尚未迁移为原生配置，或配置不可读: %w", e))
		return
	}
	if r.Method != "GET" {
		fail(w, fmt.Errorf("此入口仅诊断%s；普通部署保留现场文件。会话策略请使用专用面板保存草稿并维护应用，玩法与经济请使用当前配置来源的专用入口", strings.Join(nativeConfigNames, "/")))
		return
	}
	respond(w, 200, map[string]any{
		"read_only": true,
		"policy":    "server_owned_diagnostics",
		"path":      dir,
		"files":     files,
		"revision":  revision,
	})
}
