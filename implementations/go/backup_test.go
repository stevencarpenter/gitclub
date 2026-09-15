package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestBackupAccountReadAccess(t *testing.T) {
	s := testServer(t, t.TempDir())
	tokens := map[string]string{}
	for _, name := range []string{"owner", "gitclub-dr", "outsider"} {
		uid := s.insert("INSERT INTO users(username,password_hash,created_at) VALUES(?,'unused',1)", name)
		tokens[name] = s.newToken(uid)
	}
	s.exec("INSERT INTO namespaces(name,kind) VALUES('owner','user'),('gitclub-dr','user')")
	s.exec("INSERT INTO namespace_members(namespace,user_id,role) VALUES('owner',1,'admin'),('gitclub-dr',2,'admin')")
	s.exec("INSERT INTO repositories(owner,name,visibility,created_at,updated_at) VALUES('owner','private','private',1,1),('gitclub-dr','own','private',1,1),('owner','public','public',1,1)")
	for _, repo := range s.rows("SELECT * FROM repositories") {
		if err := s.initializeRepo(repo); err != nil {
			t.Fatal(err)
		}
	}
	request := func(user, method, path string, body M, status int) *httptest.ResponseRecorder {
		t.Helper()
		payload, _ := json.Marshal(body)
		r := httptest.NewRequest(method, path, bytes.NewReader(payload))
		if user != "" {
			r.Header.Set("Authorization", "Bearer "+tokens[user])
		}
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		s.ServeHTTP(w, r)
		if w.Code != status {
			t.Fatalf("%s %s as %s: got %d want %d: %s", method, path, user, w.Code, status, w.Body.String())
		}
		return w
	}
	decode := func(w *httptest.ResponseRecorder) M {
		t.Helper()
		var out M
		if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		return out
	}
	listRoles := func(user, path, key, name string) map[string]string {
		t.Helper()
		result := map[string]string{}
		for _, raw := range decode(request(user, "GET", path, nil, 200))[key].([]any) {
			item := raw.(map[string]any)
			result[str(item, name)] = str(item, "role")
		}
		return result
	}
	if err := s.configureBackupUser(""); err != nil {
		t.Fatal(err)
	}
	request("gitclub-dr", "GET", "/api/repos/1", nil, 404)
	request("gitclub-dr", "GET", "/owner/private.git/info/refs?service=git-upload-pack", nil, 404)
	if roles := listRoles("gitclub-dr", "/api/repos", "repositories", "full_name"); len(roles) != 2 || roles["gitclub-dr/own"] != "admin" || roles["owner/public"] != "read" {
		t.Fatalf("unset backup configuration changed ordinary repository access: %v", roles)
	}
	if roles := listRoles("gitclub-dr", "/api/namespaces", "namespaces", "name"); len(roles) != 1 || roles["gitclub-dr"] != "admin" {
		t.Fatalf("unset backup configuration changed namespace access: %v", roles)
	}
	if err := s.configureBackupUser("gitclub-dr"); err != nil || s.backupUserID != 2 {
		t.Fatalf("resolve existing backup account: id=%d error=%v", s.backupUserID, err)
	}
	if s.isBackupUser(nil) || s.isBackupUser(M{"username": "gitclub-dr"}) || s.isBackupUser(M{"id": int64(3), "username": "gitclub-dr"}) {
		t.Fatal("backup access must require the resolved authenticated user ID")
	}
	request("owner", "POST", "/api/namespaces", M{"name": "later"}, 201)
	created := decode(request("owner", "POST", "/api/repos", M{"owner": "later", "name": "after-config"}, 201))["repository"].(map[string]any)
	rid := num(created, "id")
	apiPath := fmt.Sprintf("/api/repos/%d", rid)
	gitPath := "/later/after-config.git"
	git := func(input string, args ...string) string {
		t.Helper()
		out, err := s.gitRunInput(rid, input, args...)
		if err != nil {
			t.Fatal(err)
		}
		return strings.TrimSpace(string(out))
	}
	blob := git("private backup fixture\n", "hash-object", "-w", "--stdin")
	tree := git("100644 blob "+blob+"\tREADME.md\n", "mktree")
	oid := git("", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit-tree", tree, "-m", "Private fixture")
	git("", "update-ref", "refs/heads/main", oid)
	if roles := listRoles("gitclub-dr", "/api/repos", "repositories", "full_name"); len(roles) != 4 || roles["owner/private"] != "read" || roles["later/after-config"] != "read" || roles["gitclub-dr/own"] != "admin" {
		t.Fatalf("backup account missed a private repository or lost ordinary membership: %v", roles)
	}
	if roles := listRoles("gitclub-dr", "/api/namespaces", "namespaces", "name"); len(roles) != 3 || roles["owner"] != "read" || roles["later"] != "read" || roles["gitclub-dr"] != "admin" {
		t.Fatalf("backup account missed a new namespace or lost membership: %v", roles)
	}
	request("gitclub-dr", "GET", apiPath, nil, 200)
	if str(decode(request("gitclub-dr", "GET", apiPath+"/blob?path=README.md", nil, 200)), "content") != "private backup fixture\n" {
		t.Fatal("backup account could not read private Git content")
	}
	request("outsider", "GET", apiPath, nil, 404)
	request("", "GET", apiPath, nil, 404)
	request("gitclub-dr", "PATCH", apiPath, M{"description": "denied"}, 403)
	request("gitclub-dr", "POST", apiPath+"/pulls", M{"title": "denied", "head_branch": "feature"}, 403)
	request("gitclub-dr", "POST", apiPath+"/git/pre-receive", M{"updates": []any{}}, 403)
	request("gitclub-dr", "POST", "/api/repos", M{"owner": "later", "name": "denied"}, 403)
	request("gitclub-dr", "POST", "/api/namespaces/later/members", M{"username": "gitclub-dr", "role": "admin"}, 403)
	request("gitclub-dr", "PATCH", "/api/repos/2", M{"description": "own membership still works"}, 200)
	request("gitclub-dr", "GET", gitPath+"/info/refs?service=git-upload-pack", nil, 200)
	request("gitclub-dr", "GET", gitPath+"/info/refs?service=git-receive-pack", nil, 403)
	request("gitclub-dr", "POST", gitPath+"/git-receive-pack", nil, 403)
	spoofed := httptest.NewRequest("GET", gitPath+"/info/refs?service=git-upload-pack", nil)
	spoofed.SetBasicAuth("gitclub-dr", tokens["outsider"])
	w := httptest.NewRecorder()
	s.ServeHTTP(w, spoofed)
	if w.Code != 404 {
		t.Fatalf("Basic username impersonation changed token identity: %d", w.Code)
	}
	s.sshSecret = "backup-test-transport-secret"
	keyID := s.insert("INSERT INTO ssh_keys(user_id,title,public_key,created_at) VALUES(2,'Backup fixture','ssh-ed25519 fixture',1)")
	for operation, status := range map[string]int{"git-upload-pack": 200, "git-receive-pack": 403} {
		payload, _ := json.Marshal(M{"key_id": keyID, "command": operation + " 'later/after-config.git'"})
		r := httptest.NewRequest("POST", "/api/ssh/authorize", bytes.NewReader(payload))
		r.Header.Set("X-GitClub-SSH-Secret", s.sshSecret)
		w := httptest.NewRecorder()
		s.ServeHTTP(w, r)
		if w.Code != status {
			t.Fatalf("backup SSH %s: got %d want %d", operation, w.Code, status)
		}
	}
	func() {
		httpServer := httptest.NewServer(s)
		defer httpServer.Close()
		clone := filepath.Join(t.TempDir(), "backup.git")
		run := func(args ...string) ([]byte, error) {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, "git", args...)
			cmd.Env = append(safeGitEnv(), "GIT_CONFIG_COUNT=1", "GIT_CONFIG_KEY_0=http.extraHeader", "GIT_CONFIG_VALUE_0=Authorization: Bearer "+tokens["gitclub-dr"])
			return cmd.CombinedOutput()
		}
		if out, err := run("clone", "--mirror", httpServer.URL+gitPath, clone); err != nil {
			t.Fatalf("backup mirror clone failed: %v: %s", err, out)
		}
		if out, err := run("--git-dir="+clone, "cat-file", "-p", "HEAD:README.md"); err != nil || string(out) != "private backup fixture\n" {
			t.Fatalf("mirror lacks private repository content: %v", err)
		}
		if _, err := run("--git-dir="+clone, "push", httpServer.URL+gitPath, "HEAD:refs/heads/denied"); err == nil {
			t.Fatal("backup fallback read access allowed a Git push")
		}
	}()
	if got := git("", "for-each-ref", "refs/heads/denied"); got != "" {
		t.Fatal("denied backup push changed repository refs")
	}
	if err := s.configureBackupUser(""); err != nil {
		t.Fatal(err)
	}
	request("gitclub-dr", "GET", apiPath, nil, 404)
	if err := s.configureBackupUser("future-backup"); err == nil || !strings.Contains(err.Error(), "create the backup account before enabling") || s.backupUserID != 0 {
		t.Fatalf("missing backup account must fail closed: id=%d error=%v", s.backupUserID, err)
	}
	newID := s.insert("INSERT INTO users(username,password_hash,created_at) VALUES('future-backup','unused',1)")
	if s.isBackupUser(M{"id": newID, "username": "future-backup"}) {
		t.Fatal("later registration acquired a previously unresolved backup grant")
	}
}
