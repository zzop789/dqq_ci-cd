package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
)

// Import stores reviewed bytes only. Activation is a separate maintenance job.
func (a *App) receiveMigration(w http.ResponseWriter, r *http.Request) {
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 4<<20))
	if err != nil {
		fail(w, err)
		return
	}
	sum := sha256.Sum256(data)
	hash := hex.EncodeToString(sum[:])
	if hash != r.URL.Query().Get("sha256") {
		fail(w, errors.New("迁移输入 SHA256 不符"))
		return
	}
	var input struct {
		Schema      int               `json:"schema_version"`
		Artifact    string            `json:"artifact_sha256"`
		SourceTree  string            `json:"source_tree"`
		SourceData  string            `json:"source_data_sha256"`
		OldDLL      string            `json:"old_dll_sha256"`
		ApprovalRef string            `json:"approval_ref"`
		ApprovalSHA string            `json:"approval_sha256"`
		Approval    []byte            `json:"approval_document"`
		Reset       bool              `json:"session_rejoin_approved"`
		Closed      bool              `json:"ingress_closed"`
		Files       map[string][]byte `json:"files"`
		Report      json.RawMessage   `json:"report"`
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if err = d.Decode(&input); err != nil {
		fail(w, err)
		return
	}
	if d.Decode(new(any)) != io.EOF {
		fail(w, errors.New("迁移输入有尾随数据"))
		return
	}
	approval := sha256.Sum256(input.Approval)
	if input.Schema != 1 || !hashPattern.MatchString(input.Artifact) || !hashPattern.MatchString(input.SourceData) || !hashPattern.MatchString(input.OldDLL) || input.SourceTree == "" || input.ApprovalRef == "" || len(input.Approval) == 0 || hex.EncodeToString(approval[:]) != input.ApprovalSHA || !input.Reset || !input.Closed || len(input.Files) != 3 || len(input.Report) == 0 {
		fail(w, errors.New("缺少明确迁移输入、批准文档或排空/重新入场确认"))
		return
	}
	for _, name := range []string{"host.json", "gameplay.lua", "economy.lua"} {
		if len(input.Files[name]) == 0 {
			fail(w, errors.New("候选配置不完整"))
			return
		}
	}
	dir := filepath.Join(a.home, "migrations")
	if err = os.MkdirAll(dir, 0700); err != nil {
		fail(w, err)
		return
	}
	f, err := os.CreateTemp(dir, "incoming-")
	if err != nil {
		fail(w, err)
		return
	}
	defer os.Remove(f.Name())
	defer f.Close()
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if err == nil {
		target := filepath.Join(dir, hash+".json")
		if old, e := os.ReadFile(target); e == nil {
			if !bytes.Equal(old, data) {
				err = errors.New("已存在候选冲突")
			}
		} else if os.IsNotExist(e) {
			err = os.Rename(f.Name(), target)
		} else {
			err = e
		}
	}
	if err != nil {
		fail(w, err)
		return
	}
	respond(w, 200, map[string]string{"sha256": hash, "status": "imported_not_activated"})
}
