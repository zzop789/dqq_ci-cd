package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"time"
)

var hashPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)

const maxArtifact = 512 << 20

// Artifacts become visible only after a complete, bounded, hash-verified upload.
func (a *App) receiveArtifact(w http.ResponseWriter, r *http.Request) {
	hash := r.URL.Query().Get("sha256")
	if !hashPattern.MatchString(hash) {
		fail(w, errors.New("SHA256 无效"))
		return
	}
	dir := filepath.Join(a.home, "uploads")
	if err := os.MkdirAll(dir, 0700); err != nil {
		fail(w, err)
		return
	}
	f, err := os.CreateTemp(dir, "incoming-*")
	if err != nil {
		fail(w, err)
		return
	}
	defer os.Remove(f.Name())
	defer f.Close()
	h := sha256.New()
	_, err = io.Copy(io.MultiWriter(f, h), http.MaxBytesReader(w, r.Body, maxArtifact))
	if err == nil && hex.EncodeToString(h.Sum(nil)) != hash {
		err = errors.New("上传校验失败")
	}
	if err == nil {
		err = f.Sync()
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		fail(w, err)
		return
	}
	// Never overwrite an artifact a worker may already be reading.
	final := filepath.Join(dir, hash+".zip")
	a.mu.Lock()
	if _, e := os.Stat(final); os.IsNotExist(e) {
		err = os.Rename(f.Name(), final)
	} else if e != nil {
		err = e
	}
	a.mu.Unlock()
	if err != nil {
		fail(w, err)
		return
	}
	respond(w, 200, map[string]string{"artifact": hash})
}

func (a *App) localArtifacts(w http.ResponseWriter, r *http.Request) bool {
	switch {
	case r.URL.Path == "/api/local-jobs" && r.Method == "GET":
		respond(w, 200, a.jobs())
	case r.URL.Path == "/api/local-build" && r.Method == "POST":
		var j Job
		if err := decode(w, r, &j); err != nil {
			fail(w, err)
			return true
		}
		j.Action = "localbuild"
		j.Commit = ""
		j.Artifact = ""
		j.Expected = ""
		j.Maintenance = false
		if err := a.submit(&j); err != nil {
			fail(w, err)
		} else {
			respond(w, 202, j)
		}
	case r.URL.Path == "/api/local-log" && r.Method == "GET":
		id := r.URL.Query().Get("id")
		if !idPattern.MatchString(id) {
			fail(w, errors.New("任务 ID 无效"))
			return true
		}
		f, e := os.Open(filepath.Join(a.home, "jobs", id+".log"))
		if e != nil {
			respond(w, 200, map[string]string{"text": "日志尚未生成"})
			return true
		}
		defer f.Close()
		s, e := f.Stat()
		if e != nil {
			fail(w, e)
			return true
		}
		if s.Size() > 200000 {
			f.Seek(-200000, io.SeekEnd)
		}
		b, e := io.ReadAll(f)
		if e != nil {
			fail(w, e)
		} else {
			respond(w, 200, map[string]string{"text": string(b)})
		}
	case r.URL.Path == "/api/upload-local" && r.Method == "POST":
		var input struct {
			ID string `json:"id"`
		}
		if e := decode(w, r, &input); e != nil {
			fail(w, e)
			return true
		}
		if !idPattern.MatchString(input.ID) {
			fail(w, errors.New("任务 ID 无效"))
			return true
		}
		var j Job
		if e := readJSON(filepath.Join(a.home, "jobs", input.ID+".json"), &j); e != nil || j.Action != "localbuild" || j.Status != "succeeded" || !hashPattern.MatchString(j.Artifact) {
			fail(w, errors.New("请选择成功的本机构建"))
			return true
		}
		a.mu.Lock()
		target, c := a.target, a.cfg
		a.mu.Unlock()
		if target == "" {
			fail(w, errors.New("请先连接远端"))
			return true
		}
		check, err := http.NewRequestWithContext(r.Context(), "GET", target+"/api/ping", nil)
		if err != nil {
			fail(w, err)
			return true
		}
		check.Header.Set("X-CICD-Token", c.Token)
		probe, err := (&http.Client{Timeout: 5 * time.Second}).Do(check)
		if err != nil {
			fail(w, err)
			return true
		}
		var capability map[string]string
		probeErr := json.NewDecoder(io.LimitReader(probe.Body, 4096)).Decode(&capability)
		probe.Body.Close()
		if probe.StatusCode != 200 || probeErr != nil || capability["native_maintenance"] != "v1" {
			fail(w, errors.New("远端Agent尚未升级到新版维护流程。请先运行更新包的update-remote.ps1，再上传部署"))
			return true
		}
		f, e := os.Open(filepath.Join(a.home, "local-artifacts", j.ID, "package.zip"))
		if e != nil {
			fail(w, e)
			return true
		}
		defer f.Close()
		req, e := http.NewRequestWithContext(r.Context(), "PUT", target+"/api/artifacts?sha256="+j.Artifact, f)
		if e != nil {
			fail(w, e)
			return true
		}
		req.Header.Set("X-CICD-Token", c.Token)
		client := http.Client{Timeout: 10 * time.Minute}
		res, e := client.Do(req)
		if e != nil {
			fail(w, fmt.Errorf("上传未确认，可重试同一制品：%w", e))
			return true
		}
		defer res.Body.Close()
		if res.StatusCode != 200 {
			b, _ := io.ReadAll(io.LimitReader(res.Body, 4096))
			fail(w, fmt.Errorf("远端拒绝制品：%s", b))
			return true
		}
		respond(w, 200, map[string]string{"artifact": j.Artifact})
	default:
		return false
	}
	return true
}
