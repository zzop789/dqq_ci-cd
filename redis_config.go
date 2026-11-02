package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	redisRequestLimit     = 4 << 20
	redisOutputLimit      = 8 << 20
	redisErrorLimit       = 64 << 10
	redisComponentLimit   = 512 << 20
	redisOperationTimeout = 60 * time.Second
)

var redisReleasePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)
var redisHashPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)

func isRedisConfigPath(path string) bool {
	return path == "/api/redis-config" || strings.HasPrefix(path, "/api/redis-config/")
}

func redisConfigError(w http.ResponseWriter, status int, code, message string) {
	respond(w, status, map[string]string{"status": "error", "code": code, "error": message})
}

// This route uses the existing authenticated SSH tunnel. Only its larger JSON
// bodies and longer, bounded validation operations have different proxy limits.
func (a *App) proxyRedisConfig(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	target, token := a.target, a.cfg.Token
	a.mu.Unlock()
	if target == "" {
		redisConfigError(w, http.StatusServiceUnavailable, "configuration_unavailable", "请先连接远端管理通道")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, redisRequestLimit))
	if err != nil {
		redisConfigError(w, http.StatusBadRequest, "configuration_error", "请求无法读取或超过4MiB")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), redisOperationTimeout)
	defer cancel()
	endpoint := target + "/api/" + strings.TrimPrefix(r.URL.Path, "/api/remote/")
	if r.URL.RawQuery != "" {
		endpoint += "?" + r.URL.RawQuery
	}
	req, err := http.NewRequestWithContext(ctx, r.Method, endpoint, bytes.NewReader(body))
	if err != nil {
		redisConfigError(w, http.StatusBadRequest, "configuration_error", "无法建立配置请求")
		return
	}
	req.Header.Set("X-CICD-Token", token)
	req.Header.Set("Content-Type", "application/json")
	client := *a.client
	client.Timeout = redisOperationTimeout
	res, err := client.Do(req)
	if err != nil {
		redisConfigError(w, http.StatusServiceUnavailable, "configuration_unavailable", "配置管理通道中断或超时；写入结果可能未知，请重新读取当前版本，勿自动重试发布")
		return
	}
	defer res.Body.Close()
	output, err := io.ReadAll(io.LimitReader(res.Body, redisOutputLimit+1))
	if err != nil || len(output) > redisOutputLimit {
		redisConfigError(w, http.StatusBadGateway, "configuration_error", "远端响应无法读取或超过8MiB，请重新读取版本状态")
		return
	}
	if !json.Valid(output) {
		redisConfigError(w, http.StatusBadGateway, "configuration_unavailable", "远端Agent尚未提供Redis配置接口，或返回了无效响应；需要通过现有流程更新管理器")
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(res.StatusCode)
	_, _ = w.Write(output)
}

func redisQuery(r *http.Request, names ...string) (url.Values, error) {
	query, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil || len(query) != len(names) {
		return nil, errors.New("查询参数不完整或包含未知参数")
	}
	for _, name := range names {
		values, ok := query[name]
		if !ok || len(values) != 1 || !idPattern.MatchString(values[0]) {
			return nil, fmt.Errorf("%s 必须是32位小写十六进制版本ID", name)
		}
	}
	return query, nil
}

// Reject duplicate JSON keys as well as unknown struct fields and extra values;
// every value_json stays text so the browser cannot round large integer values.
func redisUniqueJSON(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var value func(int) error
	value = func(depth int) error {
		if depth > 64 {
			return errors.New("JSON嵌套超过64层")
		}
		token, err := decoder.Token()
		if err != nil {
			return err
		}
		delim, compound := token.(json.Delim)
		if !compound {
			return nil
		}
		switch delim {
		case '{':
			seen := map[string]bool{}
			for decoder.More() {
				keyToken, err := decoder.Token()
				if err != nil {
					return err
				}
				key, ok := keyToken.(string)
				if !ok || seen[key] {
					return errors.New("JSON对象包含重复字段")
				}
				seen[key] = true
				if err := value(depth + 1); err != nil {
					return err
				}
			}
		case '[':
			for decoder.More() {
				if err := value(depth + 1); err != nil {
					return err
				}
			}
		default:
			return errors.New("JSON结构无效")
		}
		_, err = decoder.Token()
		return err
	}
	if err := value(0); err != nil {
		return err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return errors.New("只允许一个完整JSON值")
	}
	return nil
}

func redisDecode(w http.ResponseWriter, r *http.Request, target any) ([]byte, error) {
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, redisRequestLimit))
	if err != nil {
		return nil, errors.New("请求无法读取或超过4MiB")
	}
	if err := redisUniqueJSON(data); err != nil {
		return nil, errors.New("JSON格式无效、重复字段或嵌套过深")
	}
	var fields []string
	switch r.URL.Path {
	case "/api/redis-config/draft":
		fields = []string{"base_version_id", "changes"}
	case "/api/redis-config/validate":
		fields = []string{"version_id"}
	case "/api/redis-config/publish":
		fields = []string{"version_id", "expected_active_id", "rollback"}
	default:
		return nil, errors.New("未知JSON接口")
	}
	object, err := redisExactFields(data, fields...)
	if err != nil {
		return nil, err
	}
	if r.URL.Path == "/api/redis-config/draft" {
		var changes []json.RawMessage
		if json.Unmarshal(object["changes"], &changes) != nil {
			return nil, errors.New("changes必须是修改数组")
		}
		for _, change := range changes {
			if _, err := redisExactFields(change, "path", "value_json"); err != nil {
				return nil, err
			}
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return nil, errors.New("JSON字段或类型不符合接口要求")
	}
	return data, nil
}

func redisExactFields(data []byte, names ...string) (map[string]json.RawMessage, error) {
	var object map[string]json.RawMessage
	if json.Unmarshal(data, &object) != nil || len(object) != len(names) {
		return nil, errors.New("JSON字段必须与接口要求完全一致")
	}
	for _, name := range names {
		if _, ok := object[name]; !ok {
			return nil, errors.New("JSON字段缺失或大小写不匹配")
		}
	}
	return object, nil
}

func redisCommand(w http.ResponseWriter, r *http.Request) ([]string, []byte, error) {
	if r.Method == http.MethodGet {
		var body [1]byte
		if n, err := r.Body.Read(body[:]); n != 0 || (err != nil && err != io.EOF) {
			return nil, nil, errors.New("GET不接受请求体")
		}
		switch r.URL.Path {
		case "/api/redis-config", "/api/redis-config/history":
			if _, err := redisQuery(r); err != nil {
				return nil, nil, err
			}
			if r.URL.Path == "/api/redis-config/history" {
				return []string{"config-list"}, nil, nil
			}
			return []string{"config-edit-read", "--version", "active"}, nil, nil
		case "/api/redis-config/version":
			query, err := redisQuery(r, "id")
			if err != nil {
				return nil, nil, err
			}
			return []string{"config-edit-read", "--version", query.Get("id")}, nil, nil
		case "/api/redis-config/diff":
			query, err := redisQuery(r, "base", "version")
			if err != nil {
				return nil, nil, err
			}
			return []string{"config-diff", "--base", query.Get("base"), "--version", query.Get("version")}, nil, nil
		}
	}
	if r.Method != http.MethodPost {
		return nil, nil, errors.New("该接口仅接受约定的GET或POST方法")
	}
	if _, err := redisQuery(r); err != nil {
		return nil, nil, err
	}
	switch r.URL.Path {
	case "/api/redis-config/draft":
		var request struct {
			Base    string `json:"base_version_id"`
			Changes []struct {
				Path      string  `json:"path"`
				ValueJSON *string `json:"value_json"`
			} `json:"changes"`
		}
		data, err := redisDecode(w, r, &request)
		if err != nil {
			return nil, nil, err
		}
		if !idPattern.MatchString(request.Base) || len(request.Changes) == 0 || len(request.Changes) > 1024 {
			return nil, nil, errors.New("草稿需合法基础版本及1至1024项修改")
		}
		seen := map[string]bool{}
		for _, change := range request.Changes {
			if change.Path == "" || len(change.Path) > 1024 || strings.ContainsAny(change.Path, "\x00\r\n") || seen[change.Path] || change.ValueJSON == nil {
				return nil, nil, errors.New("修改路径缺失、重复或无效，value_json必须是JSON文本字符串")
			}
			seen[change.Path] = true
			if err := redisUniqueJSON([]byte(*change.ValueJSON)); err != nil {
				return nil, nil, errors.New("value_json必须包含一个合法且无重复字段的JSON值")
			}
		}
		return []string{"config-draft", "--stdin"}, data, nil
	case "/api/redis-config/validate":
		var request struct {
			Version string `json:"version_id"`
		}
		if _, err := redisDecode(w, r, &request); err != nil {
			return nil, nil, err
		}
		if !idPattern.MatchString(request.Version) {
			return nil, nil, errors.New("version_id必须是32位小写十六进制版本ID")
		}
		return []string{"config-validate", "--version", request.Version}, nil, nil
	case "/api/redis-config/publish":
		var request struct {
			Version  string `json:"version_id"`
			Expected string `json:"expected_active_id"`
			Rollback *bool  `json:"rollback"`
		}
		if _, err := redisDecode(w, r, &request); err != nil {
			return nil, nil, err
		}
		if !idPattern.MatchString(request.Version) || !idPattern.MatchString(request.Expected) || request.Rollback == nil {
			return nil, nil, errors.New("发布需明确version_id、expected_active_id及rollback布尔值")
		}
		args := []string{"config-publish", "--version", request.Version, "--expected", request.Expected, "--editor"}
		if *request.Rollback {
			args = append(args, "--rollback")
		}
		return args, nil, nil
	default:
		return nil, nil, errors.New("未知Redis配置接口")
	}
}

func (a *App) redisConfig(w http.ResponseWriter, r *http.Request) {
	args, input, err := redisCommand(w, r)
	if err != nil {
		redisConfigError(w, http.StatusBadRequest, "configuration_error", err.Error())
		return
	}
	a.mu.Lock()
	if a.active || a.blocked || a.redisPending {
		a.mu.Unlock()
		redisConfigError(w, http.StatusConflict, "configuration_conflict", "已有部署或配置操作执行中，或部署等待恢复，请完成后重新读取")
		return
	}
	a.redisPending = true
	root := a.cfg.InstallRoot
	a.mu.Unlock()
	defer func() { a.mu.Lock(); a.redisPending = false; a.mu.Unlock() }()
	ctx, cancel := context.WithTimeout(r.Context(), redisOperationTimeout)
	defer cancel()
	output, err := runRedisConfiguration(ctx, root, args, input)
	if err != nil {
		redisConfigError(w, http.StatusServiceUnavailable, "configuration_unavailable", err.Error())
		return
	}
	var result struct {
		Status string `json:"status"`
		Code   string `json:"code"`
	}
	if json.Unmarshal(output, &result) != nil || result.Status == "" {
		redisConfigError(w, http.StatusBadGateway, "configuration_error", "redisctl返回无效JSON结果")
		return
	}
	status := http.StatusOK
	if result.Status == "error" {
		status = http.StatusBadRequest
		switch result.Code {
		case "configuration_conflict":
			status = http.StatusConflict
		case "configuration_not_found":
			status = http.StatusNotFound
		case "configuration_canceled", "configuration_timeout":
			status = http.StatusServiceUnavailable
		}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_, _ = w.Write(output)
}

type redisRelease struct{ Directory, Executable, DLLHash, Shared string }

// No browser value selects a path. Walk every existing ancestor to reject
// junctions/symlinks; a deployment's current junction is deliberately not used.
func redisPlainPath(path string, directory bool) error {
	info, err := os.Lstat(path)
	if err != nil {
		return errors.New("部署路径不存在或不可读")
	}
	if directory && !info.IsDir() || !directory && !info.Mode().IsRegular() {
		return errors.New("部署路径类型无效")
	}
	for current := path; ; current = filepath.Dir(current) {
		info, err := os.Lstat(current)
		if err != nil || info.Mode()&(os.ModeSymlink|os.ModeIrregular) != 0 {
			return errors.New("部署路径不得经过链接或重解析点")
		}
		if parent := filepath.Dir(current); parent == current {
			break
		}
	}
	return nil
}

func redisReadMetadata(ctx context.Context, path string, target any) error {
	if err := ctx.Err(); err != nil {
		return errors.New("读取部署元数据已取消或超时")
	}
	if err := redisPlainPath(path, false); err != nil {
		return err
	}
	file, err := os.Open(path)
	if err != nil {
		return errors.New("部署元数据不可读")
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, redisOutputLimit+1))
	if err != nil || len(data) > redisOutputLimit {
		return errors.New("部署元数据无法读取或过大")
	}
	if err := ctx.Err(); err != nil {
		return errors.New("读取部署元数据已取消或超时")
	}
	data = bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf})
	if err := redisUniqueJSON(data); err != nil {
		return errors.New("部署元数据JSON无效")
	}
	if err := json.Unmarshal(data, target); err != nil {
		return errors.New("部署元数据字段无效")
	}
	return nil
}

func redisVerifyHash(ctx context.Context, path, expected string) error {
	if err := ctx.Err(); err != nil {
		return errors.New("发行版组件校验已取消或超时")
	}
	if !redisHashPattern.MatchString(expected) {
		return errors.New("发行版缺少合法文件SHA256，拒绝执行配置工具")
	}
	if err := redisPlainPath(path, false); err != nil {
		return err
	}
	file, err := os.Open(path)
	if err != nil {
		return errors.New("发行版组件不可读")
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > redisComponentLimit {
		return errors.New("发行版组件必须是非空且不超过512MiB的普通文件")
	}
	hash := sha256.New()
	buffer := make([]byte, 64<<10)
	var total int64
	for {
		if err := ctx.Err(); err != nil {
			return errors.New("发行版组件校验已取消或超时")
		}
		count, readErr := file.Read(buffer)
		if err := ctx.Err(); err != nil {
			return errors.New("发行版组件校验已取消或超时")
		}
		total += int64(count)
		if total > redisComponentLimit || total > info.Size() {
			return errors.New("发行版组件在校验期间变化或超过512MiB")
		}
		if count > 0 {
			_, _ = hash.Write(buffer[:count])
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return errors.New("发行版组件无法校验")
		}
	}
	if total != info.Size() {
		return errors.New("发行版组件在校验期间变化")
	}
	if hex.EncodeToString(hash.Sum(nil)) != expected {
		return errors.New("发行版组件SHA256不匹配，拒绝执行配置工具")
	}
	return nil
}

func locateRedisRelease(ctx context.Context, root string) (redisRelease, error) {
	return locateManagedRelease(ctx, root, "redisctl.exe")
}

// tool is chosen only by the Agent's fixed routes, never by a browser path.
func locateManagedRelease(ctx context.Context, root, tool string) (redisRelease, error) {
	var result redisRelease
	if tool != "redisctl.exe" && tool != "hostctl.exe" && tool != "server.exe" {
		return result, errors.New("不支持的运维工具")
	}
	var state struct {
		Schema  int    `json:"schema_version"`
		Current string `json:"current_version"`
	}
	if err := redisReadMetadata(ctx, filepath.Join(root, "state", "deployment.json"), &state); err != nil {
		return result, err
	}
	if state.Schema != 1 || !redisReleasePattern.MatchString(state.Current) || strings.HasSuffix(state.Current, ".") {
		return result, errors.New("尚无合法当前发行版，请先通过现有流程部署")
	}
	result.Directory = filepath.Join(root, "releases", state.Current)
	result.Executable = filepath.Join(result.Directory, tool)
	result.Shared = filepath.Join(root, "shared")
	var identity struct {
		Schema   int    `json:"schema_version"`
		Version  string `json:"version"`
		Target   string `json:"target"`
		Gameplay string `json:"production_gameplay"`
		ABI      int    `json:"abi_version"`
		DLLHash  string `json:"dll_sha256"`
		Files    []struct {
			Path   string `json:"path"`
			SHA256 string `json:"sha256"`
		} `json:"files"`
	}
	if err := redisReadMetadata(ctx, filepath.Join(result.Directory, "RELEASE_IDENTITY.json"), &identity); err != nil {
		return result, err
	}
	if identity.Schema != 1 || identity.Version != state.Current || identity.Target != "windows/amd64" || identity.Gameplay != "cpp" || identity.ABI != 1 || !redisHashPattern.MatchString(identity.DLLHash) {
		return result, errors.New("当前发行版身份不符合配置工具要求")
	}
	hashes := map[string]string{}
	for _, file := range identity.Files {
		key := strings.ToLower(file.Path)
		if _, exists := hashes[key]; exists || !redisHashPattern.MatchString(file.SHA256) {
			return result, errors.New("发行版文件清单重复或SHA256无效")
		}
		hashes[key] = file.SHA256
	}
	if hashes[tool] == "" {
		return result, fmt.Errorf("当前发行版尚未包含受清单保护的%s；请通过现有发布流程更新，不会自动部署", tool)
	}
	if hashes["gamecore.dll"] != identity.DLLHash {
		return result, errors.New("发行版DLL身份与文件清单不一致")
	}
	if err := redisVerifyHash(ctx, result.Executable, hashes[tool]); err != nil {
		return result, err
	}
	if err := redisVerifyHash(ctx, filepath.Join(result.Directory, "gamecore.dll"), identity.DLLHash); err != nil {
		return result, err
	}
	for _, name := range []string{".env", "host.json"} {
		if err := redisPlainPath(filepath.Join(result.Shared, name), false); err != nil {
			return result, errors.New("shared/.env或host.json不存在、类型无效或不可读；请按部署流程配置，不会自动修改")
		}
	}
	result.DLLHash = identity.DLLHash
	return result, nil
}

func redisChildEnvironment(release redisRelease) []string {
	fixed := map[string]string{
		"ENV_FILE":           filepath.Join(release.Shared, ".env"),
		"SERVER_CONFIG_FILE": filepath.Join(release.Shared, "host.json"),
		"GAMECORE_DLL":       filepath.Join(release.Directory, "gamecore.dll"),
		"GAMECORE_SHA256":    release.DLLHash,
		"COMBAT_CONTENT_DIR": filepath.Join(release.Directory, "configs", "combat"),
	}
	result := make([]string, 0, len(os.Environ())+len(fixed))
	for _, pair := range os.Environ() {
		key, _, _ := strings.Cut(pair, "=")
		key = strings.ToUpper(key)
		if _, replace := fixed[key]; replace || strings.HasPrefix(key, "REDIS_") {
			continue
		}
		result = append(result, pair)
	}
	for key, value := range fixed {
		result = append(result, key+"="+value)
	}
	return result
}

type redisLimitedOutput struct {
	buffer   bytes.Buffer
	limit    int
	exceeded bool
	cancel   context.CancelFunc
}

func (output *redisLimitedOutput) Write(data []byte) (int, error) {
	count := len(data)
	remaining := output.limit - output.buffer.Len()
	if count > remaining {
		_, _ = output.buffer.Write(data[:remaining])
		output.exceeded = true
		output.cancel()
		return count, nil
	}
	_, _ = output.buffer.Write(data)
	return count, nil
}

func runRedisConfiguration(ctx context.Context, root string, args []string, input []byte) ([]byte, error) {
	if !filepath.IsAbs(root) {
		return nil, errors.New("安装根目录必须是绝对路径")
	}
	root = filepath.Clean(root)
	stateDir := filepath.Join(root, "state")
	if err := redisPlainPath(stateDir, true); err != nil {
		return nil, err
	}
	lockPath := filepath.Join(stateDir, "deployment.lock")
	if err := redisPlainPath(lockPath, false); err != nil {
		return nil, errors.New("部署锁缺失或不可读，请先完成既有部署流程")
	}
	// Windows denies this open while the worker holds FileShare.None, and denies
	// that exclusive worker open for the entire lifetime of this handle.
	lock, err := os.OpenFile(lockPath, os.O_RDWR, 0)
	if err != nil {
		return nil, errors.New("部署锁正被占用或不可访问，请等待部署结束")
	}
	defer lock.Close()
	release, err := locateRedisRelease(ctx, root)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, errors.New("发行版校验超时，请稍后重试读取")
	}
	childCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	stdout := &redisLimitedOutput{limit: redisOutputLimit, cancel: cancel}
	stderr := &redisLimitedOutput{limit: redisErrorLimit, cancel: cancel}
	cmd := exec.CommandContext(childCtx, release.Executable, args...)
	cmd.Dir = release.Directory
	cmd.Env = redisChildEnvironment(release)
	cmd.Stdin = bytes.NewReader(input)
	cmd.Stdout, cmd.Stderr = stdout, stderr
	cmd.WaitDelay = 2 * time.Second
	hide(cmd)
	err = cmd.Run()
	if stdout.exceeded || stderr.exceeded {
		return nil, errors.New("配置工具输出超过限制，已停止；写入结果可能未知，请重新读取版本状态")
	}
	if ctx.Err() != nil {
		return nil, errors.New("配置操作已取消或超过60秒；写入结果可能未知，请重新读取当前版本，勿自动重试发布")
	}
	data := bytes.TrimSpace(stdout.buffer.Bytes())
	var result struct {
		Status string `json:"status"`
		Code   string `json:"code"`
		Error  string `json:"error"`
	}
	valid := redisUniqueJSON(data) == nil && json.Unmarshal(data, &result) == nil && result.Status != ""
	if err != nil {
		if valid && result.Status == "error" && result.Error != "" {
			return data, nil
		}
		return nil, errors.New("配置工具启动或执行失败；请核对当前制品是否支持配置编辑接口；不会自动部署或修改环境")
	}
	if !valid {
		return nil, errors.New("配置工具返回无效结果，请更新匹配版本的管理器与服务端工具")
	}
	return data, nil
}
