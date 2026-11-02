package main

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAuthenticationAndHost(t *testing.T) {
	a := &App{agent: true, cfg: Config{Token: strings.Repeat("a", 32)}}
	for _, tt := range []struct {
		host, token string
		want        int
	}{{"127.0.0.1:19090", "", 401}, {"evil.example:19090", a.cfg.Token, 403}, {"127.0.0.1:19090", a.cfg.Token, 200}} {
		r := httptest.NewRequest("GET", "http://"+tt.host+"/api/ping", nil)
		r.Header.Set("X-CICD-Token", tt.token)
		w := httptest.NewRecorder()
		a.handler(w, r)
		if w.Code != tt.want {
			t.Fatalf("%s got %d", tt.host, w.Code)
		}
	}
	r := httptest.NewRequest("POST", "http://127.0.0.1:19090/api/jobs", nil)
	r.Header.Set("X-CICD-Token", a.cfg.Token)
	r.Header.Set("Origin", "https://evil.example")
	w := httptest.NewRecorder()
	a.handler(w, r)
	if w.Code != 403 {
		t.Fatal(w.Code)
	}
}
func TestJobValidation(t *testing.T) {
	base := Job{ID: strings.Repeat("a", 32), Action: "deploy", Commit: strings.Repeat("b", 40), Maintenance: true}
	if e := validateJob(&base); e != nil {
		t.Fatal(e)
	}
	invalid := []Job{{ID: "../../config", Action: "start"}, {ID: base.ID, Action: "shell"}, {ID: base.ID, Action: "deploy", Commit: "HEAD", Maintenance: true}, {ID: base.ID, Action: "deploy", Commit: base.Commit}, {ID: base.ID, Action: "stop"}}
	for _, j := range invalid {
		if validateJob(&j) == nil {
			t.Fatalf("accepted %+v", j)
		}
	}
}
func TestIdempotencyAndConflictingRequests(t *testing.T) {
	a := &App{home: t.TempDir(), active: true}
	old := Job{ID: strings.Repeat("a", 32), Action: "stop", Maintenance: true, Expected: "A", Status: "succeeded"}
	if e := a.saveJob(&old); e != nil {
		t.Fatal(e)
	}
	same := old
	same.Status = ""
	if e := a.submit(&same); e != nil || same.Status != "succeeded" {
		t.Fatalf("%v %+v", e, same)
	}
	different := old
	different.Expected = "B"
	if a.submit(&different) == nil {
		t.Fatal("conflict accepted")
	}
	fresh := old
	fresh.ID = strings.Repeat("b", 32)
	if a.submit(&fresh) == nil {
		t.Fatal("concurrent operation accepted")
	}
}
func TestStartupBlocksCheckpointAndDoesNotReplay(t *testing.T) {
	a := &App{home: t.TempDir()}
	old := Job{ID: strings.Repeat("a", 32), Action: "start", Status: "running"}
	a.saveJob(&old)
	if e := atomicJSON(filepath.Join(a.home, "checkpoint.json"), map[string]string{"version": "A"}); e != nil {
		t.Fatal(e)
	}
	a.recoverStartup()
	if !a.blocked {
		t.Fatal("missing block")
	}
	var loaded Job
	readJSON(filepath.Join(a.home, "jobs", old.ID+".json"), &loaded)
	if loaded.Status != "interrupted" {
		t.Fatal(loaded.Status)
	}
	fresh := Job{ID: strings.Repeat("b", 32), Action: "start"}
	if a.submit(&fresh) == nil {
		t.Fatal("allowed while blocked")
	}
}
func TestAtomicJSONReplacement(t *testing.T) {
	p := filepath.Join(t.TempDir(), "state.json")
	for _, v := range []string{"A", "B"} {
		if e := atomicJSON(p, map[string]string{"version": v}); e != nil {
			t.Fatal(e)
		}
	}
	var got map[string]string
	if e := readJSON(p, &got); e != nil || got["version"] != "B" {
		t.Fatal(e, got)
	}
	b, _ := os.ReadFile(p)
	if !json.Valid(b) {
		t.Fatal("partial state")
	}
}
func TestCommandInjectionRejected(t *testing.T) {
	c := Config{Host: "192.168.2.7", Port: 22, User: "alw", Key: filepath.Join(t.TempDir(), "key")}
	if e := validConfig(c); e != nil {
		t.Fatal(e)
	}
	for _, host := range []string{"-oProxyCommand=bad", "127.0.0.1;whoami", "a b"} {
		copy := c
		copy.Host = host
		if validConfig(copy) == nil {
			t.Fatal(host)
		}
	}
	c.User = "alw;whoami"
	if validConfig(c) == nil {
		t.Fatal("username injection")
	}
}
func TestLogTraversalRejected(t *testing.T) {
	a := &App{agent: true, cfg: Config{Token: strings.Repeat("x", 32)}, home: t.TempDir()}
	r := httptest.NewRequest("GET", "http://127.0.0.1:19090/api/log?id=../config", nil)
	r.Header.Set("X-CICD-Token", a.cfg.Token)
	w := httptest.NewRecorder()
	a.handler(w, r)
	if w.Code != 400 {
		t.Fatal(w.Code)
	}
}
