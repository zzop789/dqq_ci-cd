package main

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

var envKeys = []string{"HTTP_ADDR", "PUBLIC_BASE_URL"}

func envRevision(b []byte) string { return fmt.Sprintf("%x", sha256.Sum256(b)) }
func envValues(b []byte) map[string]string {
	out := map[string]string{}
	for _, line := range strings.Split(string(b), "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if ok {
			for _, allowed := range envKeys {
				if k == allowed {
					out[k] = strings.TrimSpace(v)
				}
			}
		}
	}
	return out
}
func updateEnvironment(b []byte, values map[string]string) ([]byte, error) {
	for k, v := range values {
		known := false
		for _, allowed := range envKeys {
			if k == allowed {
				known = true
			}
		}
		if !known {
			return nil, errors.New("不允许编辑此配置项")
		}
		if strings.ContainsAny(v, "\r\n\x00") {
			return nil, errors.New("配置值不能含换行")
		}
		switch k {
		case "HTTP_ADDR":
			_, p, e := net.SplitHostPort(v)
			n, err := strconv.Atoi(p)
			if e != nil || err != nil || n < 1 || n > 65535 {
				return nil, errors.New("监听地址应为 :8080 或 IP:端口")
			}
		case "PUBLIC_BASE_URL":
			u, e := url.Parse(v)
			if e != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
				return nil, errors.New("公共地址应为 http(s)://主机:端口")
			}
		}
	}
	newline := "\n"
	if strings.Contains(string(b), "\r\n") {
		newline = "\r\n"
	}
	lines := strings.SplitAfter(string(b), "\n")
	seen := map[string]bool{}
	var out strings.Builder
	for _, line := range lines {
		k, _, ok := strings.Cut(strings.TrimSpace(line), "=")
		v, change := values[k]
		if ok && change {
			if !seen[k] {
				out.WriteString(k + "=" + v + newline)
				seen[k] = true
			}
		} else {
			out.WriteString(line)
		}
	}
	for _, k := range envKeys {
		if v, ok := values[k]; ok && !seen[k] {
			if out.Len() > 0 && !strings.HasSuffix(out.String(), "\n") {
				out.WriteString(newline)
			}
			out.WriteString(k + "=" + v + newline)
		}
	}
	return []byte(out.String()), nil
}
func (a *App) environment(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	defer a.mu.Unlock()
	path := filepath.Join(a.cfg.InstallRoot, "shared", ".env")
	b, e := os.ReadFile(path)
	if e != nil {
		fail(w, e)
		return
	}
	if r.Method == "GET" {
		respond(w, 200, map[string]any{"values": envValues(b), "revision": envRevision(b)})
		return
	}
	if r.Method != "POST" {
		w.WriteHeader(405)
		return
	}
	if a.active || a.blocked || a.redisPending {
		fail(w, errors.New("远端任务执行中或待恢复，不能改配置"))
		return
	}
	var input struct {
		Revision string            `json:"revision"`
		Values   map[string]string `json:"values"`
	}
	if e = decode(w, r, &input); e != nil {
		fail(w, e)
		return
	}
	if input.Revision != envRevision(b) {
		fail(w, errors.New("配置已变化，请重新读取后保存"))
		return
	}
	updated, e := updateEnvironment(b, input.Values)
	if e != nil {
		fail(w, e)
		return
	}
	if string(updated) == string(b) {
		respond(w, 200, map[string]any{"saved": true, "changed": false})
		return
	}
	backup := path + ".bak-" + randomID()
	if e = os.WriteFile(backup, b, 0600); e != nil {
		fail(w, e)
		return
	}
	current, e := os.ReadFile(path)
	if e != nil || envRevision(current) != input.Revision {
		fail(w, errors.New("配置发生并发修改，已保留备份，未写入"))
		return
	}
	temp := path + ".tmp-" + randomID()
	defer os.Remove(temp)
	if e = os.WriteFile(temp, updated, 0600); e == nil {
		e = os.Rename(temp, path)
	}
	if e != nil {
		fail(w, e)
		return
	}
	respond(w, 200, map[string]any{"saved": true, "changed": true, "backup": backup, "revision": envRevision(updated), "restart_required": true})
}
