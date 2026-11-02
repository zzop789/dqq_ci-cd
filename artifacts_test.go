package main

import (
	"crypto/sha256"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLocalArtifactTransferUsesApprovedBytes(t *testing.T) {
	remote := &App{home: t.TempDir()}
	capable := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-CICD-Token") != "secret" {
			t.Error("missing remote authentication")
			w.WriteHeader(401)
			return
		}
		if r.URL.Path == "/api/ping" {
			profile := ""
			if capable {
				profile = "v1"
			}
			respond(w, 200, map[string]string{"native_maintenance": profile})
			return
		}
		remote.receiveArtifact(w, r)
	}))
	defer server.Close()
	local := &App{home: t.TempDir(), target: server.URL, cfg: Config{Token: "secret"}}
	data := []byte("approved package bytes")
	hash := fmt.Sprintf("%x", sha256.Sum256(data))
	j := Job{ID: strings.Repeat("d", 32), Action: "localbuild", Status: "succeeded", Artifact: hash}
	if e := local.saveJob(&j); e != nil {
		t.Fatal(e)
	}
	dir := filepath.Join(local.home, "local-artifacts", j.ID)
	os.MkdirAll(dir, 0700)
	os.WriteFile(filepath.Join(dir, "package.zip"), data, 0600)
	r := httptest.NewRequest("POST", "http://127.0.0.1:18765/api/upload-local", strings.NewReader(`{"id":"`+j.ID+`"}`))
	w := httptest.NewRecorder()
	local.localArtifacts(w, r)
	if w.Code == 200 {
		t.Fatal("old agent accepted upload")
	}
	if _, err := os.Stat(filepath.Join(remote.home, "uploads", hash+".zip")); !os.IsNotExist(err) {
		t.Fatal("bytes sent to old agent")
	}
	capable = true
	r = httptest.NewRequest("POST", "http://127.0.0.1:18765/api/upload-local", strings.NewReader(`{"id":"`+j.ID+`"}`))
	w = httptest.NewRecorder()
	local.localArtifacts(w, r)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body)
	}
	b, e := os.ReadFile(filepath.Join(remote.home, "uploads", hash+".zip"))
	if e != nil || string(b) != string(data) {
		t.Fatal(e, string(b))
	}
	if len(remote.jobs()) != 0 {
		t.Fatal("upload must not deploy automatically")
	}
}

func TestArtifactUploadIntegrityAndAuthentication(t *testing.T) {
	a := &App{agent: true, home: t.TempDir(), cfg: Config{Token: strings.Repeat("a", 32)}}
	data := "fixed artifact"
	hash := fmt.Sprintf("%x", sha256.Sum256([]byte(data)))
	for _, tc := range []struct {
		hash, body, token string
		want              int
	}{{hash, data, "", 401}, {"../config", data, a.cfg.Token, 400}, {hash, "truncated", a.cfg.Token, 400}, {hash, data, a.cfg.Token, 200}, {hash, data, a.cfg.Token, 200}} {
		r := httptest.NewRequest("PUT", "http://127.0.0.1:19090/api/artifacts?sha256="+tc.hash, strings.NewReader(tc.body))
		r.Header.Set("X-CICD-Token", tc.token)
		w := httptest.NewRecorder()
		a.handler(w, r)
		if w.Code != tc.want {
			t.Fatalf("got %d want %d: %s", w.Code, tc.want, w.Body)
		}
	}
	b, e := os.ReadFile(filepath.Join(a.home, "uploads", hash+".zip"))
	if e != nil || string(b) != data {
		t.Fatal(e, string(b))
	}
	files, _ := os.ReadDir(filepath.Join(a.home, "uploads"))
	if len(files) != 1 {
		t.Fatal("partial upload files left", len(files))
	}
}
func TestArtifactRequiresMaintenanceAndBindsRetry(t *testing.T) {
	j := Job{ID: strings.Repeat("a", 32), Action: "package", Artifact: strings.Repeat("b", 64)}
	if validateJob(&j) == nil {
		t.Fatal("maintenance omitted")
	}
	j.Maintenance = true
	if e := validateJob(&j); e != nil {
		t.Fatal(e)
	}
	a := &App{home: t.TempDir(), active: true}
	j.Status = "succeeded"
	if e := a.saveJob(&j); e != nil {
		t.Fatal(e)
	}
	retry := j
	retry.Artifact = strings.Repeat("c", 64)
	if a.submit(&retry) == nil {
		t.Fatal("artifact substitution accepted")
	}
	if e := a.submit(&j); e != nil {
		t.Fatal(e)
	}
}
func TestRemoteRejectsLocalBuild(t *testing.T) {
	a := &App{agent: true, home: t.TempDir(), cfg: Config{Token: strings.Repeat("a", 32)}}
	r := httptest.NewRequest("POST", "http://127.0.0.1:19090/api/jobs", strings.NewReader(`{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","action":"localbuild"}`))
	r.Header.Set("X-CICD-Token", a.cfg.Token)
	w := httptest.NewRecorder()
	a.handler(w, r)
	if w.Code != 400 {
		t.Fatal(w.Code)
	}
}
