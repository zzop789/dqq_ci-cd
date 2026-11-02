package main

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The configuration editors are diagnostics only: they report the live files
// and refuse every write. No validation subprocess may be started, because a
// candidate value set no longer exists.
func TestServerConfigurationReadOnly(t *testing.T) {
	t.Setenv("SERVER_CONFIG_FILE", "")
	for _, scenario := range []string{"existing", "missing", "native"} {
		t.Run(scenario, func(t *testing.T) {
			root := t.TempDir()
			os.MkdirAll(filepath.Join(root, "shared"), 0700)
			path := filepath.Join(root, "shared", "server.json")
			before := []byte("{\"game\":{\"match_players\":4},\"future\":42}\n")
			if scenario != "missing" {
				if e := os.WriteFile(path, before, 0600); e != nil {
					t.Fatal(e)
				}
			}
			if scenario == "native" {
				// A native release directory used to make the legacy editor
				// refuse to run the exclusive preflight. It must simply not run.
				dir := filepath.Join(root, "current")
				os.MkdirAll(dir, 0700)
				os.WriteFile(filepath.Join(dir, "gamecore.dll"), []byte("fixture"), 0600)
				os.WriteFile(filepath.Join(dir, "RELEASE_IDENTITY.json"), []byte("{}"), 0600)
				os.WriteFile(filepath.Join(dir, "server.exe"), []byte("not-a-program"), 0600)
			}
			app := &App{cfg: Config{InstallRoot: root}}

			get := httptest.NewRecorder()
			app.serverConfig(get, httptest.NewRequest("GET", "/api/server-config", nil))
			if get.Code != 200 {
				t.Fatal(get.Code, get.Body.String())
			}
			var view struct {
				ReadOnly bool   `json:"read_only"`
				Policy   string `json:"policy"`
				Exists   bool   `json:"exists"`
				Text     string `json:"text"`
				Revision string `json:"revision"`
			}
			if e := json.Unmarshal(get.Body.Bytes(), &view); e != nil {
				t.Fatal(e)
			}
			if !view.ReadOnly || view.Policy != "release_owned" {
				t.Fatalf("editor not marked read-only: %s", get.Body.String())
			}
			if scenario == "missing" {
				if view.Exists || view.Text != "" || view.Revision != "missing" {
					t.Fatalf("missing file reported as content: %s", get.Body.String())
				}
			} else if !view.Exists || view.Text != string(before) || view.Revision != envRevision(before) {
				t.Fatalf("unexpected snapshot: %s", get.Body.String())
			}

			body, _ := json.Marshal(map[string]any{"revision": view.Revision, "text": "{\"game\":{\"match_players\":8}}", "validate_only": false})
			post := httptest.NewRecorder()
			app.serverConfig(post, httptest.NewRequest("POST", "/api/server-config", strings.NewReader(string(body))))
			if post.Code == 200 {
				t.Fatal("write accepted")
			}
			if scenario == "missing" {
				if _, e := os.Stat(path); !os.IsNotExist(e) {
					t.Fatal("read-only editor created a file")
				}
			} else {
				after, e := os.ReadFile(path)
				if e != nil || string(after) != string(before) {
					t.Fatalf("read-only editor modified the file: %s", after)
				}
			}
			if leftovers, _ := filepath.Glob(filepath.Join(root, "shared", ".server-config-check-*")); len(leftovers) != 0 {
				t.Fatal("read-only editor started a validation candidate")
			}
			if backups, _ := filepath.Glob(path + ".bak-*"); len(backups) != 0 {
				t.Fatal("read-only editor wrote a backup")
			}
		})
	}
}

func TestServerConfigurationPath(t *testing.T) {
	root := t.TempDir()
	os.MkdirAll(filepath.Join(root, "shared"), 0700)
	custom := filepath.Join(root, "custom.json")
	t.Setenv("SERVER_CONFIG_FILE", "")
	os.WriteFile(filepath.Join(root, "shared", ".env"), []byte("SERVER_CONFIG_FILE=\""+custom+"\"\n"), 0600)
	got, e := serverConfigPath(root)
	if e != nil || got != custom {
		t.Fatal(got, e)
	}
	t.Setenv("SERVER_CONFIG_FILE", "relative.json")
	if _, e = serverConfigPath(root); e == nil {
		t.Fatal("relative path accepted")
	}
}

func TestNativeConfigurationReadOnly(t *testing.T) {
	for _, missing := range nativeConfigNames {
		t.Run("missing-"+missing, func(t *testing.T) {
			root := t.TempDir()
			dir := filepath.Join(root, "shared")
			if e := os.MkdirAll(dir, 0700); e != nil {
				t.Fatal(e)
			}
			for _, name := range nativeConfigNames {
				if name == missing {
					continue
				}
				if e := os.WriteFile(filepath.Join(dir, name), []byte("value-"+name), 0600); e != nil {
					t.Fatal(e)
				}
			}
			app := &App{cfg: Config{InstallRoot: root}}
			rec := httptest.NewRecorder()
			app.nativeConfig(rec, httptest.NewRequest("GET", "/api/native-config", nil))
			if rec.Code == 200 {
				t.Fatalf("incomplete configuration reported as readable: %s", rec.Body.String())
			}
		})
	}
	t.Run("read-and-refuse-write", func(t *testing.T) {
		root := t.TempDir()
		dir := filepath.Join(root, "shared")
		if e := os.MkdirAll(dir, 0700); e != nil {
			t.Fatal(e)
		}
		for _, name := range nativeConfigNames {
			if e := os.WriteFile(filepath.Join(dir, name), []byte("live-"+name), 0600); e != nil {
				t.Fatal(e)
			}
		}
		_, revision, e := readNativeFiles(dir)
		if e != nil {
			t.Fatal(e)
		}
		app := &App{cfg: Config{InstallRoot: root}}
		get := httptest.NewRecorder()
		app.nativeConfig(get, httptest.NewRequest("GET", "/api/native-config", nil))
		if get.Code != 200 {
			t.Fatal(get.Code, get.Body.String())
		}
		var view struct {
			ReadOnly bool              `json:"read_only"`
			Policy   string            `json:"policy"`
			Files    map[string]string `json:"files"`
			Revision string            `json:"revision"`
		}
		if e := json.Unmarshal(get.Body.Bytes(), &view); e != nil {
			t.Fatal(e)
		}
		if !view.ReadOnly || view.Policy != "release_owned" || view.Revision != revision {
			t.Fatalf("unexpected snapshot: %s", get.Body.String())
		}
		for _, name := range nativeConfigNames {
			if view.Files[name] != "live-"+name {
				t.Fatalf("missing live value for %s: %s", name, get.Body.String())
			}
		}
		body, _ := json.Marshal(map[string]any{"file": "gameplay.lua", "text": "edited", "revision": revision, "validate_only": false})
		post := httptest.NewRecorder()
		app.nativeConfig(post, httptest.NewRequest("POST", "/api/native-config", strings.NewReader(string(body))))
		if post.Code == 200 {
			t.Fatal("write accepted")
		}
		for _, name := range nativeConfigNames {
			data, e := os.ReadFile(filepath.Join(dir, name))
			if e != nil || string(data) != "live-"+name {
				t.Fatalf("read-only editor modified %s: %s", name, data)
			}
		}
		if backups, _ := filepath.Glob(filepath.Join(dir, "*.bak-*")); len(backups) != 0 {
			t.Fatal("read-only editor wrote a backup")
		}
	})
}

func TestNativeRevisionChangesWithContent(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "shared")
	if e := os.MkdirAll(dir, 0700); e != nil {
		t.Fatal(e)
	}
	for _, name := range nativeConfigNames {
		if e := os.WriteFile(filepath.Join(dir, name), []byte("value-"+name), 0600); e != nil {
			t.Fatal(e)
		}
	}
	_, first, e := readNativeFiles(dir)
	if e != nil {
		t.Fatal(e)
	}
	if e = os.WriteFile(filepath.Join(dir, "economy.lua"), []byte("changed"), 0600); e != nil {
		t.Fatal(e)
	}
	_, second, e := readNativeFiles(dir)
	if e != nil {
		t.Fatal(e)
	}
	if first == second {
		t.Fatal("revision did not track content")
	}
}
