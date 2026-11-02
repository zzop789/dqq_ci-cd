package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const hostAdminRequestLimit = 16 << 10

var hostAdminRequestID = regexp.MustCompile(`^[A-Za-z0-9_.:-]{16,128}$`)

type hostAdminRequest struct {
	Action             string `json:"action"`
	PlayerName         string `json:"player_name,omitempty"`
	ExpectedInstanceID string `json:"expected_instance_id,omitempty"`
	RegistrationID     string `json:"registration_id,omitempty"`
	Ingress            string `json:"ingress,omitempty"`
	RoomID             string `json:"room_id,omitempty"`
	RequestID          string `json:"request_id,omitempty"`
}

func isHostAdminPath(path string) bool {
	return path == "/api/host-admin" || strings.HasPrefix(path, "/api/host-admin/")
}

func hostAdminError(w http.ResponseWriter, status int, code, message string) {
	respond(w, status, map[string]string{"status": "error", "code": code, "error": message})
}

// Reuse the existing authenticated local page and SSH tunnel. The browser never
// receives the host's per-process administrative token or chooses its address.
func (a *App) proxyHostAdmin(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	target, token := a.target, a.cfg.Token
	a.mu.Unlock()
	if target == "" {
		hostAdminError(w, http.StatusServiceUnavailable, "host_admin_unavailable", "请先连接远端管理通道")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, hostAdminRequestLimit))
	if err != nil {
		hostAdminError(w, http.StatusBadRequest, "invalid_admin_request", "请求无法读取或超过16KiB")
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
		hostAdminError(w, http.StatusBadRequest, "invalid_admin_request", "无法建立宿主管理请求")
		return
	}
	req.Header.Set("X-CICD-Token", token)
	req.Header.Set("Content-Type", "application/json")
	client := *a.client
	client.Timeout = redisOperationTimeout
	res, err := client.Do(req)
	if err != nil {
		hostAdminError(w, http.StatusServiceUnavailable, "host_admin_unavailable", "宿主管理通道中断或超时；操作结果可能未知，请重新读取状态并保留请求ID，勿盲目重试")
		return
	}
	defer res.Body.Close()
	output, err := io.ReadAll(io.LimitReader(res.Body, redisOutputLimit+1))
	if err != nil || len(output) > redisOutputLimit || !json.Valid(output) {
		hostAdminError(w, http.StatusBadGateway, "host_admin_unavailable", "宿主管理响应无效或过大；请核对Agent和游戏制品版本，写入结果须重新读取确认")
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(res.StatusCode)
	_, _ = w.Write(output)
}

func parseHostAdminRequest(w http.ResponseWriter, r *http.Request) (hostAdminRequest, []byte, error) {
	var request hostAdminRequest
	query, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		return request, nil, errors.New("查询参数无效")
	}
	if r.Method == http.MethodGet {
		var probe [1]byte
		if n, err := r.Body.Read(probe[:]); n != 0 || (err != nil && err != io.EOF) {
			return request, nil, errors.New("GET不接受请求体")
		}
		switch r.URL.Path {
		case "/api/host-admin/rooms":
			if len(query) != 0 {
				return request, nil, errors.New("房间概览不接受查询参数")
			}
			request.Action = "rooms"
		case "/api/host-admin/sessions":
			request.Action = "sessions"
			if len(query) > 0 {
				values, ok := query["player_name"]
				if len(query) != 1 || !ok || len(values) != 1 || !validHostAdminPlayerName(values[0]) {
					return request, nil, errors.New("会话诊断仅接受一个有效的player_name")
				}
				request.PlayerName = values[0]
			}
		default:
			return request, nil, errors.New("未知宿主管理读取入口")
		}
	} else if r.Method == http.MethodPost {
		if len(query) != 0 {
			return request, nil, errors.New("管理写入不接受查询参数")
		}
		var fields []string
		switch r.URL.Path {
		case "/api/host-admin/revoke-session":
			fields = []string{"expected_instance_id", "request_id", "registration_id", "ingress"}
		case "/api/host-admin/terminate-room":
			fields = []string{"expected_instance_id", "request_id", "room_id"}
		default:
			return request, nil, errors.New("未知宿主管理写入入口")
		}
		data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, hostAdminRequestLimit))
		if err != nil || redisUniqueJSON(data) != nil {
			return request, nil, errors.New("请求JSON无效、重复字段或超过16KiB")
		}
		if _, err := redisExactFields(data, fields...); err != nil {
			return request, nil, errors.New("写入字段必须与接口完全一致，不能按玩家名执行管理操作")
		}
		if err := json.Unmarshal(data, &request); err != nil {
			return request, nil, errors.New("管理写入字段必须为字符串")
		}
		if !idPattern.MatchString(request.ExpectedInstanceID) || !hostAdminRequestID.MatchString(request.RequestID) {
			return request, nil, errors.New("写入需明确的32位实例ID和16至128位请求ID")
		}
		if r.URL.Path == "/api/host-admin/revoke-session" {
			if !idPattern.MatchString(request.RegistrationID) || (request.Ingress != "registered" && request.Ingress != "experimental") {
				return request, nil, errors.New("撤销需明确的登记ID及registered或experimental入口")
			}
			request.Action = "revoke_session"
		} else {
			if !idPattern.MatchString(request.RoomID) {
				return request, nil, errors.New("终止需明确的32位房间ID")
			}
			request.Action = "terminate_room"
		}
	} else {
		return request, nil, errors.New("该入口仅接受约定的GET或POST")
	}
	data, err := json.Marshal(request)
	return request, data, err
}

func validHostAdminPlayerName(name string) bool {
	return name != "" && len(name) <= 256 && utf8.ValidString(name) && strings.TrimSpace(name) == name && strings.IndexFunc(name, unicode.IsControl) < 0
}

func (a *App) hostAdmin(w http.ResponseWriter, r *http.Request) {
	request, input, err := parseHostAdminRequest(w, r)
	if err != nil {
		hostAdminError(w, http.StatusBadRequest, "invalid_admin_request", err.Error())
		return
	}
	a.mu.Lock()
	if a.active || a.blocked || a.redisPending {
		a.mu.Unlock()
		hostAdminError(w, http.StatusConflict, "host_admin_busy", "部署、配置或宿主管理正在执行，或有待恢复检查点；完成后重新读取")
		return
	}
	a.redisPending = true
	root := a.cfg.InstallRoot
	a.mu.Unlock()
	defer func() { a.mu.Lock(); a.redisPending = false; a.mu.Unlock() }()
	ctx, cancel := context.WithTimeout(r.Context(), redisOperationTimeout)
	defer cancel()
	output, err := runHostAdministration(ctx, root, input)
	if err != nil {
		hostAdminError(w, http.StatusServiceUnavailable, "host_admin_unavailable", err.Error())
		return
	}
	var result struct {
		Status     string `json:"status"`
		Code       string `json:"code"`
		InstanceID string `json:"instance_id"`
		RequestID  string `json:"request_id"`
		Action     string `json:"action"`
		TargetID   string `json:"target_id"`
		HTTPStatus int    `json:"http_status"`
	}
	if json.Unmarshal(output, &result) != nil || result.Status == "" {
		hostAdminError(w, http.StatusBadGateway, "host_admin_unavailable", "宿主管理返回无效结果，操作结果需重新读取确认")
		return
	}
	status := http.StatusOK
	if result.Status == "error" {
		status = http.StatusBadRequest
		switch result.Code {
		case "instance_mismatch", "host_instance_mismatch", "stale_instance", "admin_conflict", "request_conflict", "host_admin_busy":
			status = http.StatusConflict
		case "session_not_found", "room_not_found", "registration_not_found":
			status = http.StatusNotFound
		case "host_admin_unavailable", "admin_unavailable", "admin_timeout", "admin_canceled":
			status = http.StatusServiceUnavailable
		}
		if result.HTTPStatus >= 400 && result.HTTPStatus <= 599 {
			status = result.HTTPStatus
		}
	} else {
		valid := idPattern.MatchString(result.InstanceID)
		if request.RequestID != "" {
			target := request.RoomID
			if request.Action == "revoke_session" {
				target = request.RegistrationID
			}
			valid = valid && (result.Status == "accepted" || result.Status == "completed") && result.InstanceID == request.ExpectedInstanceID && result.RequestID == request.RequestID && result.Action == request.Action && result.TargetID == target
		} else {
			valid = valid && result.Status == "ok"
		}
		if !valid {
			hostAdminError(w, http.StatusBadGateway, "host_admin_unavailable", "宿主响应与请求实例或目标不匹配；请重新读取状态，不自动重发")
			return
		}
		if result.Status == "accepted" {
			status = http.StatusAccepted
		}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_, _ = w.Write(output)
}

func runHostAdministration(ctx context.Context, root string, input []byte) ([]byte, error) {
	if !filepath.IsAbs(root) {
		return nil, errors.New("安装根目录必须是绝对路径")
	}
	root = filepath.Clean(root)
	lockPath := filepath.Join(root, "state", "deployment.lock")
	if err := redisPlainPath(lockPath, false); err != nil {
		return nil, errors.New("部署锁缺失或不可读，请先完成既有部署流程")
	}
	lock, err := os.OpenFile(lockPath, os.O_RDWR, 0)
	if err != nil {
		return nil, errors.New("部署锁正被占用或不可访问，请等待维护结束")
	}
	defer lock.Close()
	release, err := locateManagedRelease(ctx, root, "hostctl.exe")
	if err != nil {
		return nil, err
	}
	if ctx.Err() != nil {
		return nil, errors.New("发行版校验超时，请稍后重试读取")
	}
	childCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	stdout := &redisLimitedOutput{limit: redisOutputLimit, cancel: cancel}
	stderr := &redisLimitedOutput{limit: redisErrorLimit, cancel: cancel}
	cmd := exec.CommandContext(childCtx, release.Executable, "request", "--stdin")
	cmd.Dir = release.Directory
	cmd.Env = redisChildEnvironment(release)
	cmd.Stdin = bytes.NewReader(input)
	cmd.Stdout, cmd.Stderr = stdout, stderr
	cmd.WaitDelay = 2 * time.Second
	hide(cmd)
	err = cmd.Run()
	if stdout.exceeded || stderr.exceeded || ctx.Err() != nil {
		return nil, errors.New("宿主管理操作取消、超时或输出超限；写入结果可能未知，请保留请求ID并重新读取，勿盲目重试")
	}
	data := bytes.TrimSpace(stdout.buffer.Bytes())
	var result struct {
		Status string `json:"status"`
		Error  string `json:"error"`
	}
	valid := redisUniqueJSON(data) == nil && json.Unmarshal(data, &result) == nil && result.Status != ""
	if err != nil {
		if valid && result.Status == "error" && result.Error != "" {
			return data, nil
		}
		return nil, errors.New("宿主管理工具执行失败；请核对当前制品、管理员权限及宿主状态，写入结果须重新读取确认")
	}
	if !valid {
		return nil, errors.New("宿主管理工具返回无效结果，请核对匹配版本并重新读取")
	}
	return data, nil
}
