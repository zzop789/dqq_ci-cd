package main

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEnvironmentSave(t *testing.T) {
	root := t.TempDir()
	os.MkdirAll(filepath.Join(root, "shared"), 0700)
	p := filepath.Join(root, "shared", ".env")
	before := []byte("# keep\r\nDB_PASSWORD=hidden\r\nDUEL_MATCH_PLAYERS=8\r\nHTTP_ADDR=:8080\r\n")
	os.WriteFile(p, before, 0600)
	a := &App{cfg: Config{InstallRoot: root}}
	get := httptest.NewRecorder()
	a.environment(get, httptest.NewRequest("GET", "/api/environment", nil))
	if strings.Contains(get.Body.String(), "hidden") {
		t.Fatal("secret leaked")
	}
	body, _ := json.Marshal(map[string]any{"revision": envRevision(before), "values": map[string]string{"HTTP_ADDR": ":8081"}})
	req := func() *httptest.ResponseRecorder {
		w := httptest.NewRecorder()
		a.environment(w, httptest.NewRequest("POST", "/api/environment", strings.NewReader(string(body))))
		return w
	}
	a.active = true
	if req().Code != 400 {
		t.Fatal("saved during deployment")
	}
	a.active = false
	if w := req(); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	after, _ := os.ReadFile(p)
	if string(after) != strings.Replace(string(before), "HTTP_ADDR=:8080", "HTTP_ADDR=:8081", 1) {
		t.Fatal("other settings changed")
	}
	backups, _ := filepath.Glob(p + ".bak-*")
	if len(backups) != 1 {
		t.Fatal("missing backup")
	}
	b, _ := os.ReadFile(backups[0])
	if string(b) != string(before) {
		t.Fatal("incorrect backup")
	}
	if req().Code != 400 {
		t.Fatal("stale save allowed")
	}
}
func TestEnvironmentValidation(t *testing.T) {
	for _, v := range []map[string]string{{"DB_PASSWORD": "x"}, {"DUEL_MATCH_PLAYERS": "8"}, {"DUEL_TOTAL_ROUNDS": "10"}, {"DUEL_MATCH_PLAYERS": "4\nEVIL=x"}, {"HTTP_ADDR": ":99999"}, {"PUBLIC_BASE_URL": "file:///x"}} {
		if _, e := updateEnvironment(nil, v); e == nil {
			t.Fatal("accepted", v)
		}
	}
}
