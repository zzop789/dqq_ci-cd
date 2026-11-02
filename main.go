package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

//go:embed ui.html
var page string

type Config struct {
	Host        string `json:"host"`
	Port        int    `json:"port"`
	User        string `json:"user"`
	Key         string `json:"key"`
	Token       string `json:"token"`
	Repo        string `json:"repo"`
	Branch      string `json:"branch"`
	Root        string `json:"root"`
	InstallRoot string `json:"install_root"`
	HealthURL   string `json:"health_url"`
	LocalRepo   string `json:"local_repo"`
}
type Job struct {
	HostPolicyDraft string `json:"host_policy_draft,omitempty"`
	Migration       string `json:"migration,omitempty"`
	Artifact        string `json:"artifact"`
	ID              string `json:"id"`
	Action          string `json:"action"`
	Commit          string `json:"commit"`
	Maintenance     bool   `json:"maintenance"`
	Expected        string `json:"expected"`
	Status          string `json:"status"`
	Error           string `json:"error"`
	Created         string `json:"created"`
	Finished        string `json:"finished"`
}
type App struct {
	mu           sync.Mutex
	cfg          Config
	home         string
	agent        bool
	session      string
	active       bool
	blocked      bool
	redisPending bool // Serializes Redis configuration and live host administration.
	tunnel       *exec.Cmd
	target       string
	client       *http.Client
}

var idPattern = regexp.MustCompile(`^[a-f0-9]{32}$`)
var shaPattern = regexp.MustCompile(`^[a-f0-9]{40}$`)

func randomID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}
func atomicJSON(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".write-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if _, err = f.Write(b); err == nil {
		err = f.Sync()
	}
	ce := f.Close()
	if err != nil {
		return err
	}
	if ce != nil {
		return ce
	}
	return os.Rename(tmp, path)
}
func readJSON(path string, v any) error {
	b, e := os.ReadFile(path)
	if e != nil {
		return e
	}
	return json.Unmarshal(bytes.TrimPrefix(b, []byte{239, 187, 191}), v)
}
func respond(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func fail(w http.ResponseWriter, e error) { respond(w, 400, map[string]string{"error": e.Error()}) }
func decode(w http.ResponseWriter, r *http.Request, v any) error {
	return json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024*1024)).Decode(v)
}
func (a *App) config() Config { a.mu.Lock(); defer a.mu.Unlock(); return a.cfg }
func (a *App) saveJob(j *Job) error {
	return atomicJSON(filepath.Join(a.home, "jobs", j.ID+".json"), j)
}
func (a *App) jobs() []Job {
	out := []Job{}
	files, _ := filepath.Glob(filepath.Join(a.home, "jobs", "*.json"))
	for _, p := range files {
		var j Job
		if readJSON(p, &j) == nil {
			out = append(out, j)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Created > out[j].Created })
	return out
}
func validConfig(c Config) error {
	if net.ParseIP(c.Host) == nil && !regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9.-]*$`).MatchString(c.Host) {
		return errors.New("主机必须为 IP 或主机名")
	}
	if c.Port < 1 || c.Port > 65535 {
		return errors.New("SSH 端口无效")
	}
	if !regexp.MustCompile(`^[A-Za-z0-9_.\\-]+$`).MatchString(c.User) {
		return errors.New("SSH 用户名无效")
	}
	if !filepath.IsAbs(c.Key) {
		return errors.New("密钥必须是绝对路径")
	}
	return nil
}
func (a *App) handler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-Frame-Options", "DENY")
	hostname, _, e := net.SplitHostPort(r.Host)
	if e != nil || hostname != "127.0.0.1" {
		respond(w, 403, map[string]string{"error": "仅接受回环主机访问"})
		return
	}
	if !a.agent && r.URL.Path == "/" && r.Method == "GET" {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		io.WriteString(w, strings.ReplaceAll(page, "__SESSION__", a.session))
		return
	}
	secret := a.session
	if a.agent {
		secret = a.config().Token
	}
	if subtle.ConstantTimeCompare([]byte(r.Header.Get("X-CICD-Token")), []byte(secret)) != 1 {
		respond(w, 401, map[string]string{"error": "未授权"})
		return
	}
	if origin := r.Header.Get("Origin"); origin != "" {
		u, e := url.Parse(origin)
		if e != nil || u.Host != r.Host {
			respond(w, 403, map[string]string{"error": "跨站请求已拒绝"})
			return
		}
	}
	if !a.agent {
		a.local(w, r)
		return
	}
	a.remote(w, r)
}
func (a *App) local(w http.ResponseWriter, r *http.Request) {
	if strings.HasPrefix(r.URL.Path, "/api/remote/") && isHostPolicyPath("/api/"+strings.TrimPrefix(r.URL.Path, "/api/remote/")) {
		a.proxyHostAdmin(w, r)
		return
	}
	if strings.HasPrefix(r.URL.Path, "/api/remote/") && isHostAdminPath("/api/"+strings.TrimPrefix(r.URL.Path, "/api/remote/")) {
		a.proxyHostAdmin(w, r)
		return
	}
	if strings.HasPrefix(r.URL.Path, "/api/remote/") && isRedisConfigPath("/api/"+strings.TrimPrefix(r.URL.Path, "/api/remote/")) {
		a.proxyRedisConfig(w, r)
		return
	}
	if a.localArtifacts(w, r) {
		return
	}
	switch {
	case r.URL.Path == "/api/exit" && r.Method == "POST":
		a.mu.Lock()
		building := a.active || a.redisPending
		a.mu.Unlock()
		if building {
			fail(w, errors.New("本机构建正在执行，请等待完成后退出"))
			return
		}
		respond(w, 200, map[string]bool{"closed": true})
		go func() {
			time.Sleep(300 * time.Millisecond)
			a.mu.Lock()
			if a.tunnel != nil {
				_ = a.tunnel.Process.Kill()
			}
			a.mu.Unlock()
			os.Exit(0)
		}()
	case r.URL.Path == "/api/config" && r.Method == "GET":
		c := a.config()
		c.Token = ""
		respond(w, 200, c)
	case r.URL.Path == "/api/config" && r.Method == "POST":
		var c Config
		if e := decode(w, r, &c); e != nil {
			fail(w, e)
			return
		}
		if e := validConfig(c); e != nil {
			fail(w, e)
			return
		}
		a.mu.Lock()
		c.Token = a.cfg.Token
		c.Root = a.cfg.Root
		c.Repo = a.cfg.Repo
		c.Branch = a.cfg.Branch
		c.InstallRoot = a.cfg.InstallRoot
		c.HealthURL = a.cfg.HealthURL
		c.LocalRepo = a.cfg.LocalRepo
		e := atomicJSON(filepath.Join(a.home, "config.json"), c)
		if e == nil {
			a.cfg = c
			if a.tunnel != nil {
				_ = a.tunnel.Process.Kill()
				a.tunnel = nil
			}
			a.target = ""
		}
		a.mu.Unlock()
		if e != nil {
			fail(w, e)
			return
		}
		respond(w, 200, map[string]bool{"saved": true})
	case r.URL.Path == "/api/connect" && r.Method == "POST":
		if e := a.connect(); e != nil {
			fail(w, e)
			return
		}
		respond(w, 200, map[string]bool{"connected": true})
	case r.URL.Path == "/api/source" && r.Method == "GET":
		c := a.config()
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()
		head, e := command(ctx, "git", "-C", c.LocalRepo, "rev-parse", "HEAD")
		if e != nil {
			fail(w, e)
			return
		}
		dirty, _ := command(ctx, "git", "-C", c.LocalRepo, "status", "--porcelain")
		respond(w, 200, map[string]any{"commit": strings.TrimSpace(string(head)), "dirty": len(dirty) > 0, "changes": string(dirty)})
	case strings.HasPrefix(r.URL.Path, "/api/remote/"):
		a.mu.Lock()
		target := a.target
		c := a.cfg
		a.mu.Unlock()
		if target == "" {
			fail(w, errors.New("请先连接远端"))
			return
		}
		limit := int64(1024 * 1024)
		if r.URL.Path == "/api/remote/migrations" {
			limit = 4 << 20
		}
		body := http.MaxBytesReader(w, r.Body, limit)
		req, e := http.NewRequestWithContext(r.Context(), r.Method, target+"/api/"+strings.TrimPrefix(r.URL.Path, "/api/remote/")+"?"+r.URL.RawQuery, body)
		if e != nil {
			fail(w, e)
			return
		}
		req.Header.Set("X-CICD-Token", c.Token)
		req.Header.Set("Content-Type", "application/json")
		res, e := a.client.Do(req)
		if e != nil {
			fail(w, fmt.Errorf("管理通道不可达，状态未知：%w", e))
			return
		}
		defer res.Body.Close()
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(res.StatusCode)
		io.Copy(w, io.LimitReader(res.Body, 2*1024*1024))
	default:
		http.NotFound(w, r)
	}
}
func command(ctx context.Context, name string, args ...string) ([]byte, error) {
	c := exec.CommandContext(ctx, name, args...)
	hide(c)
	b, e := c.CombinedOutput()
	if e != nil {
		return b, fmt.Errorf("%s: %w: %s", name, e, b)
	}
	return b, nil
}
func (a *App) connect() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	c := a.cfg
	if e := validConfig(c); e != nil {
		return e
	}
	if a.tunnel != nil {
		_ = a.tunnel.Process.Kill()
		a.tunnel = nil
	}
	a.target = ""
	l, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		return e
	}
	port := l.Addr().(*net.TCPAddr).Port
	l.Close()
	args := []string{"-N", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "-o", "IdentitiesOnly=yes", "-i", c.Key, "-p", fmt.Sprint(c.Port), "-L", fmt.Sprintf("127.0.0.1:%d:127.0.0.1:19090", port), c.User + "@" + c.Host}
	cmd := exec.Command("ssh.exe", args...)
	hide(cmd)
	logFile, e := os.OpenFile(filepath.Join(a.home, "ssh.log"), os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if e != nil {
		return e
	}
	cmd.Stderr = logFile
	if e = cmd.Start(); e != nil {
		logFile.Close()
		return e
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait(); logFile.Close() }()
	target := fmt.Sprintf("http://127.0.0.1:%d", port)
	for i := 0; i < 40; i++ {
		select {
		case e := <-done:
			b, _ := os.ReadFile(filepath.Join(a.home, "ssh.log"))
			return fmt.Errorf("SSH 失败：%v %s", e, b)
		default:
		}
		req, _ := http.NewRequest("GET", target+"/api/ping", nil)
		req.Header.Set("X-CICD-Token", c.Token)
		client := http.Client{Timeout: 300 * time.Millisecond}
		res, e := client.Do(req)
		if e == nil {
			res.Body.Close()
			if res.StatusCode == 200 {
				a.tunnel = cmd
				a.target = target
				return nil
			}
			cmd.Process.Kill()
			return errors.New("SSH 已连接，但部署程序认证失败；请核对两端 config.json 的 token")
		}
		time.Sleep(200 * time.Millisecond)
	}
	cmd.Process.Kill()
	return errors.New("远端部署程序未响应，请先安装并启动 ZYF-CICD-Agent；查看 ssh.log")
}
func (a *App) remote(w http.ResponseWriter, r *http.Request) {
	if isHostPolicyPath(r.URL.Path) {
		a.hostPolicy(w, r)
		return
	}
	if isHostAdminPath(r.URL.Path) {
		a.hostAdmin(w, r)
		return
	}
	if isRedisConfigPath(r.URL.Path) {
		a.redisConfig(w, r)
		return
	}
	if r.URL.Path == "/api/migrations" && r.Method == "PUT" {
		a.receiveMigration(w, r)
		return
	}
	if r.URL.Path == "/api/native-config" {
		a.nativeConfig(w, r)
		return
	}
	if r.URL.Path == "/api/server-config" {
		a.serverConfig(w, r)
		return
	}
	if r.URL.Path == "/api/environment" {
		a.environment(w, r)
		return
	}
	if r.URL.Path == "/api/artifacts" && r.Method == "PUT" {
		a.receiveArtifact(w, r)
		return
	}
	switch {
	case r.URL.Path == "/api/ping" && r.Method == "GET":
		respond(w, 200, map[string]string{"service": "zyf-cicd-agent", "version": "2.1.0", "native_maintenance": "v1", "native_migration": "offline-v1", "host_policy": "v1"})
	case r.URL.Path == "/api/status" && r.Method == "GET":
		c := a.config()
		if b, e := os.ReadFile(filepath.Join(c.InstallRoot, "shared", ".env")); e == nil {
			if _, port, e := net.SplitHostPort(envValues(b)["HTTP_ADDR"]); e == nil {
				c.HealthURL = "http://127.0.0.1:" + port
			}
		}
		a.mu.Lock()
		active, blocked := a.active, a.blocked
		a.mu.Unlock()
		out := map[string]any{"agent": "online", "time": time.Now().UTC().Format(time.RFC3339), "active": active, "blocked": blocked, "repo": c.Repo, "branch": c.Branch, "install_root": c.InstallRoot}
		var state any
		if readJSON(filepath.Join(c.InstallRoot, "state", "deployment.json"), &state) == nil {
			out["deployment"] = state
		}
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		req, _ := http.NewRequestWithContext(ctx, "GET", c.HealthURL+"/version", nil)
		res, e := a.client.Do(req)
		if e == nil {
			defer res.Body.Close()
			var v any
			if res.StatusCode == 200 && json.NewDecoder(res.Body).Decode(&v) == nil {
				out["game"] = v
			} else {
				out["game_error"] = "版本探针异常"
			}
		} else {
			out["game_error"] = "游戏服未响应（停止或探针异常）"
		}
		respond(w, 200, out)
	case r.URL.Path == "/api/jobs" && r.Method == "GET":
		respond(w, 200, a.jobs())
	case r.URL.Path == "/api/log" && r.Method == "GET":
		id := r.URL.Query().Get("id")
		if !idPattern.MatchString(id) {
			fail(w, errors.New("任务 ID 无效"))
			return
		}
		p := filepath.Join(a.home, "jobs", id+".log")
		f, e := os.Open(p)
		if e != nil {
			respond(w, 200, map[string]string{"text": "日志尚未生成"})
			return
		}
		defer f.Close()
		s, _ := f.Stat()
		if s.Size() > 200000 {
			f.Seek(-200000, io.SeekEnd)
		}
		b, _ := io.ReadAll(f)
		respond(w, 200, map[string]string{"text": string(b)})
	case r.URL.Path == "/api/jobs" && r.Method == "POST":
		var j Job
		if e := decode(w, r, &j); e != nil {
			fail(w, e)
			return
		}
		if j.Action == "localbuild" {
			fail(w, errors.New("本机构建不能在远端执行"))
			return
		}
		if e := a.submit(&j); e != nil {
			fail(w, e)
			return
		}
		respond(w, 202, j)
	default:
		http.NotFound(w, r)
	}
}
func validateJob(j *Job) error {
	if !idPattern.MatchString(j.ID) {
		return errors.New("任务 ID 无效")
	}
	switch j.Action {
	case "host-policy":
		if !idPattern.MatchString(j.HostPolicyDraft) || !j.Maintenance || !redisReleasePattern.MatchString(j.Expected) || j.Artifact != "" || j.Commit != "" {
			return errors.New("会话策略应用需明确草稿、当前版本及维护确认")
		}
	case "localbuild":
	case "migration":
		if !hashPattern.MatchString(j.Migration) || !hashPattern.MatchString(j.Artifact) || !j.Maintenance {
			return errors.New("迁移需候选/制品 SHA256 和维护确认")
		}
	case "package":
		if !hashPattern.MatchString(j.Artifact) {
			return errors.New("制品 SHA256 无效")
		}
	case "build", "deploy":
		if !shaPattern.MatchString(j.Commit) {
			return errors.New("必须选择完整的 40 位提交 SHA")
		}
	case "start", "stop", "rollback", "recover":
	default:
		return errors.New("不支持的操作")
	}
	if j.Action != "migration" && j.Migration != "" {
		return errors.New("普通部署不接受迁移候选")
	}
	if j.Action != "host-policy" && j.HostPolicyDraft != "" {
		return errors.New("其他任务不接受会话策略草稿")
	}
	if (j.Action == "package" || j.Action == "deploy" || j.Action == "stop" || j.Action == "rollback" || j.Action == "recover") && !j.Maintenance {
		return errors.New("当前为维护发布，必须确认可能中断内存对局")
	}
	return nil
}
func (a *App) submit(j *Job) error {
	if e := validateJob(j); e != nil {
		return e
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	var old Job
	if readJSON(filepath.Join(a.home, "jobs", j.ID+".json"), &old) == nil {
		if old.HostPolicyDraft != j.HostPolicyDraft || old.Migration != j.Migration || old.Artifact != j.Artifact || old.Action != j.Action || old.Commit != j.Commit || old.Expected != j.Expected || old.Maintenance != j.Maintenance {
			return errors.New("同一任务 ID 参数不同")
		}
		*j = old
		return nil
	}
	if a.active || a.redisPending {
		return errors.New("已有任务执行中，请等待完成")
	}
	if a.blocked && j.Action != "recover" {
		return errors.New("上次部署中断，必须先执行恢复检查点")
	}
	j.Status = "queued"
	j.Created = time.Now().UTC().Format(time.RFC3339Nano)
	j.Error = ""
	j.Finished = ""
	if e := a.saveJob(j); e != nil {
		return e
	}
	a.active = true
	copy := *j
	go a.run(copy)
	return nil
}
func (a *App) run(j Job) {
	defer func() {
		a.mu.Lock()
		a.active = false
		var pending any
		a.blocked = readJSON(filepath.Join(a.home, "checkpoint.json"), &pending) == nil
		a.mu.Unlock()
	}()
	j.Status = "running"
	if e := a.saveJob(&j); e != nil {
		return
	}
	f, e := os.OpenFile(filepath.Join(a.home, "jobs", j.ID+".log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if e == nil {
		script := "worker.ps1"
		policyMode := ""
		if j.Action == "host-policy" {
			script, policyMode = "host-policy-worker.ps1", "Apply"
		} else if j.Action == "recover" {
			var checkpoint struct {
				Format string `json:"format"`
			}
			if readJSON(filepath.Join(a.home, "checkpoint.json"), &checkpoint) == nil && checkpoint.Format == "host-policy-v1" {
				script, policyMode = "host-policy-worker.ps1", "Recover"
			}
		}
		if j.Action == "localbuild" {
			script = "local-build.ps1"
		}
		args := []string{"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(a.home, script), "-HomeDir", a.home, "-JobID", j.ID}
		if policyMode != "" {
			args = append(args, "-Mode", policyMode)
		}
		c := exec.Command("powershell.exe", args...)
		hide(c)
		c.Stdout = f
		c.Stderr = f
		c.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "GCM_INTERACTIVE=Never", "GOMAXPROCS=2", "GOFLAGS=-p=2")
		// Windows PowerShell must not inherit PowerShell 7's incompatible module paths.
		c.Env = append(c.Env, "PSModulePath="+filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "Modules")+";"+filepath.Join(os.Getenv("ProgramFiles"), "WindowsPowerShell", "Modules"))
		e = runWorker(c)
		if e == nil && j.Action == "localbuild" {
			var result struct {
				Artifact string `json:"artifact"`
			}
			e = readJSON(filepath.Join(a.home, "local-artifacts", j.ID, "result.json"), &result)
			j.Artifact = result.Artifact
			if e == nil && !hashPattern.MatchString(j.Artifact) {
				e = errors.New("构建结果缺少 SHA256")
			}
		}
		f.Close()
	}
	if e != nil {
		j.Status = "failed"
		j.Error = e.Error() + "；请查看任务日志"
	} else {
		j.Status = "succeeded"
	}
	j.Finished = time.Now().UTC().Format(time.RFC3339Nano)
	if err := a.saveJob(&j); err != nil {
		log.Print(err)
	}
}
func (a *App) recoverStartup() {
	var checkpoint any
	a.blocked = readJSON(filepath.Join(a.home, "checkpoint.json"), &checkpoint) == nil
	for _, j := range a.jobs() {
		if j.Status == "running" || j.Status == "queued" {
			j.Status = "interrupted"
			j.Error = "部署程序重启，未重复执行。若存在检查点，请恢复后再发布。"
			_ = a.saveJob(&j)
		}
	}
}
func main() {
	agent := flag.Bool("agent", false, "run remote agent")
	home := flag.String("home", "", "configuration directory")
	flag.Parse()
	if *home == "" {
		exe, _ := os.Executable()
		*home = filepath.Dir(exe)
	}
	var cfg Config
	if e := readJSON(filepath.Join(*home, "config.json"), &cfg); e != nil {
		log.Fatal(e)
	}
	if len(cfg.Token) < 32 {
		log.Fatal("config token missing")
	}
	a := &App{cfg: cfg, home: *home, agent: *agent, session: randomID(), client: &http.Client{Timeout: 12 * time.Second}}
	run := func() error {
		a.recoverStartup()
		port := "127.0.0.1:18765"
		if a.agent {
			port = "127.0.0.1:19090"
			a.recoverStartup()
		}
		l, e := net.Listen("tcp", port)
		if e != nil {
			return e
		}
		if !a.agent {
			fmt.Println("管理器：http://" + port)
			openBrowser("http://" + port)
		}
		return (&http.Server{Handler: http.HandlerFunc(a.handler), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16384}).Serve(l)
	}
	if *agent {
		if ok, e := serviceRun(run, func() bool { a.mu.Lock(); defer a.mu.Unlock(); return !a.active && !a.redisPending }); ok {
			if e != nil {
				log.Fatal(e)
			}
			return
		}
	}
	if e := run(); e != nil {
		log.Fatal(e)
	}
}
