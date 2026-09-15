package main

import (
	"encoding/json"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

func TestKaneoURLs(t *testing.T) {
	project := "https://kaneo.example/dashboard/workspace/ws-1/project/p_2"
	for _, suffix := range []string{"", "/board", "/list", "/overview"} {
		if got := kaneoProjectURL(project + suffix); got != project+"/board" {
			t.Fatalf("project canonicalization: %s", got)
		}
	}
	for _, suffix := range []string{"/task/task_3", "/board?taskId=task_3", "/list?taskId=task_3"} {
		if got := kaneoTaskURL(strings.Replace(project, "kaneo.example", "KANEO.EXAMPLE:443", 1)+suffix, project+"/board"); got != project+"/task/task_3" {
			t.Fatalf("task canonicalization: %s", got)
		}
	}
	if kaneoProjectURL("") != "" || kaneoTaskURL("", "") != "" {
		t.Fatal("empty URLs must clear links")
	}
	reject := func(name string, f func()) {
		t.Helper()
		t.Run(name, func(t *testing.T) {
			defer func() {
				if e, ok := recover().(apiError); !ok || e.status != 400 {
					t.Errorf("expected validation error, got %v", e)
				}
			}()
			f()
		})
	}
	for _, value := range []any{nil, true, 123, "http://kaneo.example/dashboard/workspace/ws/project/p", "https://user@kaneo.example/dashboard/workspace/ws/project/p", project + "#", project + "/board?view=mine", project + "/board?", project + "/task/t", project + "/../other", strings.Replace(project, "ws-1", "%77s-1", 1), strings.Replace(project, "ws-1", strings.Repeat("w", 101), 1), strings.Repeat("x", 2049)} {
		reject("invalid_project", func() { kaneoProjectURL(value) })
	}
	for _, value := range []any{nil, 123, project + "/task/t?x=y", project + "/task/t#fragment", project + "/board?taskId=t&x=y", project + "/board?taskId=t&taskId=t", project + "/overview?taskId=t", project + "/task/../t", project + "/task/with.dots", project + "/task/" + strings.Repeat("t", 101), strings.Replace(project, "kaneo.example", "other.example", 1) + "/task/t", strings.Replace(project, "ws-1", "other", 1) + "/task/t", strings.Replace(project, "p_2", "other", 1) + "/task/t"} {
		reject("invalid_task", func() { kaneoTaskURL(value, project+"/board") })
	}
	reject("project_required", func() { kaneoTaskURL(project+"/task/t", "") })
	path := "/dashboard/workspace/ws/project/p"
	longProject := "https://" + strings.Repeat("h", 2048-len("https://")-len(path)) + path
	reject("canonical_project_length", func() { kaneoProjectURL(longProject) })
}

func TestKaneoMigrationAndAPI(t *testing.T) {
	s := testServer(t, t.TempDir())
	// Recreate the pre-Kaneo schema in this test's disposable database schema.
	s.exec("ALTER TABLE repositories DROP COLUMN kaneo_project_url")
	s.exec("ALTER TABLE pull_requests DROP COLUMN kaneo_task_url")
	s.exec("DELETE FROM schema_migrations WHERE version='002_kaneo'")
	tokens := map[string]string{}
	for _, name := range []string{"owner", "writer", "reader", "other", "outsider"} {
		uid := s.insert("INSERT INTO users(username,password_hash,created_at) VALUES(?,'unused',?)", name, now())
		tokens[name] = s.newToken(uid)
	}
	s.exec("INSERT INTO namespaces(name,kind) VALUES('owner','user')")
	s.exec("INSERT INTO namespace_members(namespace,user_id,role) VALUES('owner',1,'admin')")
	s.exec("INSERT INTO repositories(owner,name,created_at,updated_at) VALUES('owner','test',?,?)", now(), now())
	s.exec("INSERT INTO repo_members(repo_id,user_id,role) VALUES(1,2,'write'),(1,3,'read'),(1,4,'write')")
	s.exec("INSERT INTO issues(repo_id,author_id,title,body,created_at,updated_at) VALUES(1,1,'Existing issue','Historical body',1,1)")
	s.exec("INSERT INTO comments(repo_id,target_type,target_id,author_id,body,created_at) VALUES(1,'issue',1,1,'Historical comment',1)")
	s.exec("INSERT INTO pull_requests(id,repo_id,author_id,title,base_branch,head_branch,created_at,updated_at) VALUES(99,1,1,'Existing pull','main','feature',1,1)")
	if err := s.migrate(); err != nil {
		t.Fatal(err)
	}
	if str(s.one("SELECT * FROM issues WHERE id=1"), "body") != "Historical body" || str(s.one("SELECT * FROM comments WHERE id=1"), "body") != "Historical comment" {
		t.Fatal("migration changed historical issue data")
	}
	repo := s.one("SELECT * FROM repositories WHERE id=1")
	if repo["kaneo_project_url"] != "" {
		t.Fatal("existing repositories must start without a Kaneo link")
	}
	if pull := s.one("SELECT * FROM pull_requests WHERE id=99"); pull["kaneo_task_url"] != "" || str(pull, "title") != "Existing pull" {
		t.Fatal("existing pull requests must be preserved without a Kaneo link")
	}
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
	parent := ""
	for i, content := range []string{"base\n", "change\n"} {
		blob := git(content, "hash-object", "-w", "--stdin")
		tree := git("100644 blob "+blob+"\tREADME.md\n", "mktree")
		args := []string{"-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit-tree", tree, "-m", content}
		if parent != "" {
			args = append(args, "-p", parent)
		}
		parent = git("", args...)
		git("", "update-ref", []string{"refs/heads/main", "refs/heads/feature"}[i], parent)
	}
	request := func(user, method, path string, b M, status int) M {
		t.Helper()
		payload, _ := json.Marshal(b)
		r := httptest.NewRequest(method, path, strings.NewReader(string(payload)))
		if user != "" {
			r.Header.Set("Authorization", "Bearer "+tokens[user])
		}
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
	project := "https://kaneo.example/dashboard/workspace/ws/project/p"
	for _, user := range []string{"writer", "reader"} {
		request(user, "PATCH", "/api/repos/1", M{"kaneo_project_url": project}, 403)
	}
	request("outsider", "PATCH", "/api/repos/1", M{"kaneo_project_url": project}, 404)
	request("owner", "PATCH", "/api/repos/1", M{"kaneo_project_url": true}, 400)
	configured := request("owner", "PATCH", "/api/repos/1", M{"kaneo_project_url": project + "/overview"}, 200)["repository"].(map[string]any)
	if str(configured, "kaneo_project_url") != project+"/board" {
		t.Fatal("repository response lacks canonical project URL")
	}
	for _, path := range []string{"/api/repos/1/issues", "/api/repos/1/issues/1", "/api/repos/1/issues/1/comments"} {
		for _, method := range []string{"GET", "POST", "PATCH", "DELETE"} {
			if str(request("reader", method, path, M{}, 410), "error") != "Issue tracking moved to Kaneo" {
				t.Fatal("issue route must identify Kaneo")
			}
			request("outsider", method, path, M{}, 404)
		}
	}
	request("", "GET", "/api/repos/1/issues", nil, 404)
	request("writer", "POST", "/api/repos/1/pulls", M{"title": "Linked change", "head_branch": "feature", "kaneo_task_url": project + "/task/t?extra=true"}, 400)
	created := request("writer", "POST", "/api/repos/1/pulls", M{"title": "Linked change", "head_branch": "feature", "kaneo_task_url": project + "/list?taskId=t"}, 201)["pull"].(map[string]any)
	if str(created, "kaneo_task_url") != project+"/task/t" {
		t.Fatal("pull response lacks canonical task URL")
	}
	request("other", "PATCH", "/api/repos/1/pulls/1", M{"kaneo_task_url": ""}, 403)
	request("reader", "PATCH", "/api/repos/1/pulls/1", M{"kaneo_task_url": ""}, 403)
	request("writer", "PATCH", "/api/repos/1/pulls/1", M{"kaneo_task_url": nil}, 400)
	request("writer", "PATCH", "/api/repos/1/pulls/1", M{"kaneo_task_url": strings.Replace(project, "/project/p", "/project/foreign", 1) + "/task/t"}, 400)
	cleared := request("writer", "PATCH", "/api/repos/1/pulls/1", M{"kaneo_task_url": ""}, 200)["pull"].(map[string]any)
	if str(cleared, "kaneo_task_url") != "" {
		t.Fatal("author could not clear task link")
	}
	request("owner", "PATCH", "/api/repos/1/pulls/1", M{"kaneo_task_url": project + "/task/other"}, 200)
	s.exec("UPDATE pull_requests SET state='merged' WHERE id=1")
	request("writer", "PATCH", "/api/repos/1/pulls/1", M{"kaneo_task_url": ""}, 409)
	request("owner", "PATCH", "/api/repos/1/pulls/1", M{"kaneo_task_url": ""}, 409)
	request("owner", "PATCH", "/api/repos/1", M{"kaneo_project_url": ""}, 200)
	if str(s.one("SELECT * FROM pull_requests WHERE id=1"), "kaneo_task_url") != project+"/task/other" {
		t.Fatal("disconnecting a project must preserve historical task links")
	}
}

func TestKaneoMergeFeedPaginationAndAccess(t *testing.T) {
	s := testServer(t, t.TempDir())
	tokens := map[string]string{}
	for _, name := range []string{"owner", "reader", "outsider"} {
		uid := s.insert("INSERT INTO users(username,password_hash,created_at) VALUES(?,'unused',1)", name)
		tokens[name] = s.newToken(uid)
	}
	s.exec("INSERT INTO namespaces(name,kind) VALUES('owner','user')")
	s.exec("INSERT INTO namespace_members(namespace,user_id,role) VALUES('owner',1,'admin')")
	s.exec("INSERT INTO repositories(owner,name,created_at,updated_at) VALUES('owner','test',1,1),('owner','other',1,1)")
	s.exec("INSERT INTO repo_members(repo_id,user_id,role) VALUES(1,2,'read')")
	task := "https://kaneo.example/dashboard/workspace/ws/project/p/task/t"
	s.exec("INSERT INTO pull_requests(repo_id,author_id,title,body,base_branch,head_branch,state,kaneo_task_url,created_at,updated_at) SELECT 1,1,'Historical pull',repeat('x',65536),'main','feature','merged',?,1,1 FROM generate_series(1,205)", task)
	s.exec("INSERT INTO pull_requests(repo_id,author_id,title,base_branch,head_branch,state,kaneo_task_url,created_at,updated_at) VALUES(1,1,'Open','main','feature','open',?,1,1),(1,1,'Closed','main','feature','closed',?,1,1),(1,1,'Unlinked','main','feature','merged','',1,1),(2,1,'Other repo','main','feature','merged',?,1,1)", task, task, task)
	request := func(user, method, path string, status int) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest(method, path, nil)
		if user != "" {
			r.Header.Set("Authorization", "Bearer "+tokens[user])
		}
		w := httptest.NewRecorder()
		s.ServeHTTP(w, r)
		if w.Code != status {
			t.Fatalf("%s %s as %s: got %d want %d", method, path, user, w.Code, status)
		}
		return w
	}
	if w := request("reader", "GET", "/api/repos/1/pulls", 200); w.Body.Len() <= 4<<20 {
		t.Fatal("fixture must reproduce a full pull history larger than the worker's 4 MiB response budget")
	}
	path := "/api/repos/1/kaneo/merges"
	after := int64(0)
	for _, count := range []int{100, 100, 5, 0} {
		w := request("reader", "GET", path+"?after_id="+strconv.FormatInt(after, 10), 200)
		if w.Body.Len() > 64<<10 {
			t.Fatal("merge feed includes oversized historical descriptions")
		}
		var out struct{ Pulls []M }
		if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		if len(out.Pulls) != count {
			t.Fatalf("after_id=%d: got %d pulls, want %d", after, len(out.Pulls), count)
		}
		for _, pull := range out.Pulls {
			if len(pull) != 4 || num(pull, "id") != after+1 || num(pull, "repo_id") != 1 || str(pull, "state") != "merged" || str(pull, "kaneo_task_url") != task {
				t.Fatalf("unexpected merge feed record: %v", pull)
			}
			after = num(pull, "id")
		}
	}
	if after != 205 {
		t.Fatalf("pagination lost merged pulls: last id %d", after)
	}
	first := request("reader", "GET", path, 200)
	if first.Body.String() != request("reader", "GET", path+"?after_id=0", 200).Body.String() {
		t.Fatal("missing cursor must start at zero")
	}
	for _, query := range []string{"after_id=", "after_id=-1", "after_id=1.5", "after_id=no", "after_id=%2B1", "after_id=9223372036854775808", "after_id=0&after_id=1", "after_id=%zz"} {
		request("reader", "GET", path+"?"+query, 400)
	}
	request("reader", "GET", path+"?after_id=9223372036854775807", 200)
	request("reader", "POST", path, 405)
	request("outsider", "GET", path, 404)
	request("", "GET", path, 404)
	request("outsider", "GET", path+"?after_id=invalid", 404)
	s.exec("UPDATE repositories SET visibility='public' WHERE id=1")
	request("", "GET", path, 401)
	request("outsider", "GET", path, 200)
}
