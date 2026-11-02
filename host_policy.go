package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"time"
)

// Mirrors the host's D-195 v1 policy. The actual installed host validates every
// candidate before it becomes applicable; this form never edits gameplay.
var hostPolicyDefaults = map[string]int{
	"pending_registration_seconds": 30, "queue_idle_seconds": 30,
	"suspect_offline_seconds": 30, "session_expire_seconds": 180,
	"lobby_heartbeat_seconds": 10, "lifecycle_sweep_seconds": 5,
	"room_failure_limit": 6, "room_failure_seconds": 120,
}

type hostPolicyDraft struct {
	Schema          int            `json:"schema_version"`
	ID              string         `json:"id"`
	Base            string         `json:"base_sha256"`
	Candidate       string         `json:"candidate_sha256"`
	Expected        string         `json:"expected_version"`
	ReleaseIdentity string         `json:"release_identity_sha256"`
	Values          map[string]int `json:"values"`
	Created         string         `json:"created"`
	Validated       bool           `json:"validated"`
	Status          string         `json:"status"`
}

func isHostPolicyPath(path string) bool {
	return path == "/api/host-policy" || path == "/api/host-policy/drafts"
}

func validateHostPolicy(values map[string]int) error {
	if len(values) != len(hostPolicyDefaults) {
		return errors.New("会话策略必须完整提供八项整数")
	}
	for key, n := range values {
		if _, ok := hostPolicyDefaults[key]; !ok {
			return errors.New("会话策略包含未知字段")
		}
		max := 86400
		if key == "room_failure_limit" {
			max = 100
		}
		if n < 1 || n > max {
			return fmt.Errorf("%s 必须为1～%d的整数", key, max)
		}
	}
	if values["suspect_offline_seconds"] >= values["session_expire_seconds"] ||
		values["queue_idle_seconds"] > values["session_expire_seconds"] ||
		values["lobby_heartbeat_seconds"] >= values["queue_idle_seconds"] ||
		values["lifecycle_sweep_seconds"] > values["queue_idle_seconds"] {
		return errors.New("需满足：疑似失联＜会话到期，队列闲置≤会话到期，心跳＜队列闲置，扫描≤队列闲置")
	}
	return nil
}

func parseHostPolicy(data []byte) (map[string]json.RawMessage, map[string]json.RawMessage, map[string]int, string, error) {
	if len(data) > 1<<20 || redisUniqueJSON(data) != nil {
		return nil, nil, nil, "", errors.New("host.json无效、重复字段或超过1MiB")
	}
	root, err := redisExactFields(data, "config_version", "runtime")
	if err != nil {
		return nil, nil, nil, "", err
	}
	var version int
	if json.Unmarshal(root["config_version"], &version) != nil || version != 3 {
		return nil, nil, nil, "", errors.New("需要schema3 host.json")
	}
	var runtime map[string]json.RawMessage
	if json.Unmarshal(root["runtime"], &runtime) != nil || runtime == nil {
		return nil, nil, nil, "", errors.New("host runtime无效")
	}
	values := make(map[string]int, len(hostPolicyDefaults))
	source := "defaults"
	if raw, ok := runtime["client_lifecycle"]; ok {
		if json.Unmarshal(raw, &values) != nil {
			return nil, nil, nil, "", errors.New("现有会话策略必须为完整整数对象")
		}
		source = "explicit"
	} else {
		for k, v := range hostPolicyDefaults {
			values[k] = v
		}
	}
	if err = validateHostPolicy(values); err != nil {
		return nil, nil, nil, "", err
	}
	return root, runtime, values, source, nil
}

func readPolicyBytes(path string) ([]byte, error) {
	if err := redisPlainPath(path, false); err != nil {
		return nil, err
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, (1<<20)+1))
	if err != nil || len(b) > 1<<20 {
		return nil, errors.New("配置文件不可读或超过1MiB")
	}
	return b, nil
}

func (a *App) hostPolicy(w http.ResponseWriter, r *http.Request) {
	if r.URL.RawQuery != "" || !(r.Method == "GET" && r.URL.Path == "/api/host-policy" || r.Method == "POST" && r.URL.Path == "/api/host-policy/drafts") {
		fail(w, errors.New("不支持的会话策略请求"))
		return
	}
	a.mu.Lock()
	if a.active || a.blocked || a.redisPending {
		a.mu.Unlock()
		fail(w, errors.New("维护或配置操作正在执行，或存在待恢复检查点"))
		return
	}
	a.redisPending = true
	root, home := a.cfg.InstallRoot, a.home
	a.mu.Unlock()
	defer func() { a.mu.Lock(); a.redisPending = false; a.mu.Unlock() }()
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	lockPath := filepath.Join(root, "state", "deployment.lock")
	if err := redisPlainPath(lockPath, false); err != nil {
		fail(w, err)
		return
	}
	lock, err := os.OpenFile(lockPath, os.O_RDWR, 0)
	if err != nil {
		fail(w, errors.New("部署锁被占用，请完成维护后重试"))
		return
	}
	defer lock.Close()
	release, err := locateManagedRelease(ctx, root, "server.exe")
	if err != nil {
		fail(w, err)
		return
	}
	hostBytes, err := readPolicyBytes(filepath.Join(release.Shared, "host.json"))
	if err != nil {
		fail(w, err)
		return
	}
	fields, runtime, values, source, err := parseHostPolicy(hostBytes)
	if err != nil {
		fail(w, err)
		return
	}
	identity, err := readPolicyBytes(filepath.Join(release.Directory, "RELEASE_IDENTITY.json"))
	if err != nil {
		fail(w, err)
		return
	}
	base, expected, identitySHA := envRevision(hostBytes), filepath.Base(release.Directory), envRevision(identity)
	if r.Method == "GET" {
		drafts := []hostPolicyDraft{}
		paths, _ := filepath.Glob(filepath.Join(home, "host-policy", "drafts", "*", "draft.json"))
		for _, path := range paths {
			var d hostPolicyDraft
			if redisReadMetadata(ctx, path, &d) == nil && d.Schema == 1 && d.Validated && idPattern.MatchString(d.ID) && filepath.Base(filepath.Dir(path)) == d.ID {
				drafts = append(drafts, d)
			}
		}
		sort.Slice(drafts, func(i, j int) bool { return drafts[i].Created > drafts[j].Created })
		if len(drafts) > 20 {
			drafts = drafts[:20]
		}
		respond(w, 200, map[string]any{"status": "ok", "values": values, "source": source, "revision": base, "expected_version": expected, "release_identity_sha256": identitySHA, "drafts": drafts, "requires_restart": true, "value_scope": "file_configuration"})
		return
	}
	input, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 16<<10))
	if err != nil || redisUniqueJSON(input) != nil {
		fail(w, errors.New("草稿请求无效或超过16KiB"))
		return
	}
	if _, err = redisExactFields(input, "revision", "values"); err != nil {
		fail(w, err)
		return
	}
	var req struct {
		Revision string         `json:"revision"`
		Values   map[string]int `json:"values"`
	}
	if json.Unmarshal(input, &req) != nil {
		fail(w, errors.New("策略必须为整数"))
		return
	}
	if req.Revision != base {
		fail(w, errors.New("host.json已变化，请重新读取"))
		return
	}
	if err = validateHostPolicy(req.Values); err != nil {
		fail(w, err)
		return
	}
	policy, _ := json.Marshal(req.Values)
	runtime["client_lifecycle"] = policy
	fields["runtime"], _ = json.Marshal(runtime)
	candidate, err := json.MarshalIndent(fields, "", "  ")
	if err != nil {
		fail(w, err)
		return
	}
	candidate = append(candidate, '\n')
	d := hostPolicyDraft{Schema: 1, ID: randomID(), Base: base, Candidate: envRevision(candidate), Expected: expected, ReleaseIdentity: identitySHA, Values: req.Values, Created: time.Now().UTC().Format(time.RFC3339Nano), Status: "unvalidated"}
	parent := filepath.Join(home, "host-policy", "drafts")
	if err = os.MkdirAll(parent, 0700); err == nil {
		err = redisPlainPath(parent, true)
	}
	dir := filepath.Join(parent, d.ID)
	if err == nil {
		err = os.Mkdir(dir, 0700)
	}
	if err == nil {
		err = os.WriteFile(filepath.Join(dir, "before-host.json"), hostBytes, 0600)
	}
	if err == nil {
		err = os.WriteFile(filepath.Join(dir, "host.json"), candidate, 0600)
	}
	if err == nil {
		err = atomicJSON(filepath.Join(dir, "draft.json"), d)
	}
	if err != nil {
		fail(w, errors.New("草稿写入失败；运行配置未修改"))
		return
	}
	// The validator reacquires the deployment lock and rechecks both identities.
	if err = lock.Close(); err != nil {
		fail(w, err)
		return
	}
	if err = validatePolicyDraft(ctx, home, d); err != nil {
		fail(w, err)
		return
	}
	d.Validated = true
	d.Status = "draft_saved"
	if err = atomicJSON(filepath.Join(dir, "draft.json"), d); err != nil {
		fail(w, err)
		return
	}
	respond(w, 200, d)
}

func validatePolicyDraft(ctx context.Context, home string, d hostPolicyDraft) error {
	child, cancel := context.WithCancel(ctx)
	defer cancel()
	stdout := &redisLimitedOutput{limit: 64 << 10, cancel: cancel}
	stderr := &redisLimitedOutput{limit: 16 << 10, cancel: cancel}
	cmd := exec.CommandContext(child, "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(home, "host-policy-worker.ps1"), "-HomeDir", home, "-Mode", "Validate", "-DraftID", d.ID)
	cmd.Dir = home
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	cmd.WaitDelay = 2 * time.Second
	hide(cmd)
	// Windows PowerShell must not inherit PowerShell 7's module directories.
	cmd.Env = append(os.Environ(), "PSModulePath="+filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "Modules")+";"+filepath.Join(os.Getenv("ProgramFiles"), "WindowsPowerShell", "Modules"))
	// A canceled HTTP request must also release the validator's child process,
	// configuration handles and Redis connection, not just its PowerShell parent.
	err := runWorker(cmd)
	if err != nil || stdout.exceeded || stderr.exceeded || ctx.Err() != nil {
		return errors.New("实际宿主未通过候选校验或校验超时；草稿不可应用，运行配置未修改。请检查Agent配套脚本、现场配置及Redis连接")
	}
	var result struct {
		Status string `json:"status"`
		ID     string `json:"draft_id"`
		SHA    string `json:"candidate_sha256"`
	}
	if json.Unmarshal(bytes.TrimSpace(stdout.buffer.Bytes()), &result) != nil || result.Status != "validated" || result.ID != d.ID || result.SHA != d.Candidate {
		return errors.New("候选校验回执不匹配，草稿不可应用")
	}
	return nil
}
