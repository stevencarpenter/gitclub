package main

import (
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMergeIntentIsDurableAndCannotOverwrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "merge.json")
	want := mergeMarker{PullID: 42, BaseBranch: "main", BaseOID: "abc", CommitOID: "def", UpdatedAt: 1234}
	if err := durableMarker(path, want); err != nil {
		t.Fatal(err)
	}
	if err := durableMarker(path, mergeMarker{PullID: 99}); err == nil {
		t.Fatal("pending merge intent was overwritten")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var got mergeMarker
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("merge recovery data: got %+v, want %+v", got, want)
	}
}

func TestPullMergeAuthorizationFreshnessAndRecovery(t *testing.T) {
	s := testServer(t, t.TempDir())
	tokens := map[string]string{}
	for _, name := range []string{"owner", "reviewer", "reader"} {
		uid := s.insert("INSERT INTO users(username,password_hash,created_at) VALUES(?,'unused',?)", name, now())
		tokens[name] = s.newToken(uid)
	}
	s.exec("INSERT INTO namespaces(name,kind) VALUES('owner','user')")
	s.exec("INSERT INTO namespace_members(namespace,user_id,role) VALUES('owner',1,'admin')")
	s.exec("INSERT INTO repositories(owner,name,created_at,updated_at) VALUES('owner','test',?,?)", now(), now())
	s.exec("INSERT INTO repo_members(repo_id,user_id,role) VALUES(1,2,'write'),(1,3,'read')")
	repo := s.one("SELECT * FROM repositories WHERE id=1")
	if err := s.initializeRepo(repo); err != nil {
		t.Fatal(err)
	}
	git := func(input string, args ...string) string {
		t.Helper()
		out, err := s.gitRunInput(1, input, args...)
		if err != nil {
			t.Fatalf("git %v: %v", args, err)
		}
		return strings.TrimSpace(string(out))
	}
	commit := func(content, parent string) string {
		t.Helper()
		blob := git(content, "hash-object", "-w", "--stdin")
		tree := git("100644 blob "+blob+"\tREADME.md\n", "mktree")
		args := []string{"-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit-tree", tree, "-m", content}
		if parent != "" {
			args = append(args, "-p", parent)
		}
		return git("", args...)
	}
	base := commit("base\n", "")
	head := commit("first change\n", base)
	git("", "update-ref", "refs/heads/main", base)
	git("", "update-ref", "refs/heads/feature", head)
	request := func(user, method, path string, b M, status int) M {
		t.Helper()
		payload, _ := json.Marshal(b)
		r := httptest.NewRequest(method, path, strings.NewReader(string(payload)))
		r.Header.Set("Authorization", "Bearer "+tokens[user])
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		s.ServeHTTP(w, r)
		if w.Code != status {
			t.Fatalf("%s %s as %s: got %d want %d: %s", method, path, user, w.Code, status, w.Body.String())
		}
		var out M
		if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		return out
	}
	request("owner", "POST", "/api/repos/1/pulls", M{"title": "Change readme", "head_branch": "feature"}, 201)
	func() {
		defer func() {
			value := recover()
			api, ok := value.(apiError)
			if !ok || api.status != 409 {
				t.Fatalf("stale settings bypassed required review: %v", value)
			}
		}()
		staleRepo := M{}
		for key, value := range repo {
			staleRepo[key] = value
		}
		staleRepo["require_review"] = false
		payload, _ := json.Marshal(M{"expected_head_oid": head})
		r := httptest.NewRequest("POST", "/api/repos/1/pulls/1/merge", strings.NewReader(string(payload)))
		s.collaborationRoutes(httptest.NewRecorder(), r, M{"id": int64(1), "username": "owner"}, staleRepo, []string{"pulls", "1", "merge"})
	}()
	request("owner", "POST", "/api/repos/1/pulls/1/reviews", M{"decision": "approve", "expected_head_oid": head}, 403)
	request("reader", "POST", "/api/repos/1/pulls/1/reviews", M{"decision": "approve", "expected_head_oid": head}, 403)
	request("reviewer", "POST", "/api/repos/1/pulls/1/reviews", M{"decision": "approve", "expected_head_oid": head}, 201)
	request("reader", "POST", "/api/repos/1/pulls/1/merge", M{"expected_head_oid": head}, 403)
	newHead := commit("second change\n", head)
	git("", "update-ref", "refs/heads/feature", newHead, head)
	request("owner", "POST", "/api/repos/1/pulls/1/merge", M{"expected_head_oid": head}, 409)
	request("reviewer", "POST", "/api/repos/1/pulls/1/reviews", M{"decision": "approve", "expected_head_oid": head}, 409)
	request("reviewer", "POST", "/api/repos/1/pulls/1/reviews", M{"decision": "approve"}, 400)
	request("owner", "POST", "/api/repos/1/pulls/1/merge", M{"expected_head_oid": newHead}, 409)
	request("reviewer", "POST", "/api/repos/1/pulls/1/reviews", M{"decision": "request_changes", "expected_head_oid": newHead}, 201)
	request("reviewer", "POST", "/api/repos/1/pulls/1/reviews", M{"decision": "comment", "body": "Still needs work", "expected_head_oid": newHead}, 201)
	request("owner", "POST", "/api/repos/1/pulls/1/merge", M{"expected_head_oid": newHead}, 409)
	request("reviewer", "POST", "/api/repos/1/pulls/1/reviews", M{"decision": "approve", "expected_head_oid": newHead}, 201)
	s.exec("UPDATE repo_members SET role='read' WHERE repo_id=1 AND user_id=2")
	request("owner", "POST", "/api/repos/1/pulls/1/merge", M{"expected_head_oid": newHead}, 409)
	s.exec("UPDATE repo_members SET role='write' WHERE repo_id=1 AND user_id=2")
	transaction := fmt.Sprintf("start\nverify refs/heads/feature %s\nupdate refs/heads/main %s %s\nprepare\ncommit\n", head, newHead, base)
	if _, err := s.gitRunInput(1, transaction, "update-ref", "--stdin"); err == nil {
		t.Fatal("stale head verification accepted")
	}
	if actual := git("", "rev-parse", "main"); actual != base {
		t.Fatal("failed transaction changed base")
	}
	s.exec("CREATE FUNCTION reject_merge() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'injected metadata failure'; END; $$ LANGUAGE plpgsql")
	s.exec("CREATE TRIGGER reject_merge BEFORE UPDATE ON pull_requests FOR EACH ROW WHEN (NEW.state='merged') EXECUTE FUNCTION reject_merge()")
	request("owner", "POST", "/api/repos/1/pulls/1/merge", M{"expected_head_oid": newHead}, 500)
	merged := git("", "rev-parse", "main")
	if merged == base {
		t.Fatal("merge did not update Git before injected metadata failure")
	}
	if _, err := os.Stat(s.markerPath(1, 1)); err != nil {
		t.Fatalf("missing recovery marker: %v", err)
	}
	s.exec("DROP TRIGGER reject_merge ON pull_requests")
	s.exec("DROP FUNCTION reject_merge()")
	result := request("owner", "GET", "/api/repos/1/pulls/1", nil, 200)
	p := result["pull"].(map[string]any)
	if str(p, "state") != "merged" || str(p, "merged_oid") != merged {
		t.Fatalf("not reconciled: %v", p)
	}
	if str(result, "head_oid") != newHead || str(result, "base_oid") != base {
		t.Fatalf("merged diff tips changed: %v", result)
	}
	if _, err := os.Stat(s.markerPath(1, 1)); !os.IsNotExist(err) {
		t.Fatalf("reconciled marker remains: %v", err)
	}
	if author := git("", "show", "-s", "--format=%an", merged); author != "owner" {
		t.Fatalf("merge author %q", author)
	}
	request("owner", "POST", "/api/repos/1/pulls/1/merge", M{"expected_head_oid": newHead}, 409)
}

func TestDiscussionTextRejectsInvalidInput(t *testing.T) {
	for _, input := range []any{nil, 3, "", " \n", "contains\x00nul", string(make([]byte, 241))} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("accepted invalid title %q", input)
				}
			}()
			discussionText(M{"title": input}, "title", true, 240)
		}()
	}
	if got := discussionText(M{"title": "Review branch permissions"}, "title", true, 240); got != "Review branch permissions" {
		t.Fatal(got)
	}
}
