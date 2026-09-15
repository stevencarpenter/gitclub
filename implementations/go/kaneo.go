package main

import (
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

var kaneoID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,100}$`)

func parseKaneoURL(value any) (*url.URL, []string) {
	raw, ok := value.(string)
	if !ok || len(raw) > 2048 {
		fail(400, "Kaneo URL must be text of at most 2048 bytes")
	}
	if raw == "" {
		return nil, nil
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || strings.Contains(raw, "#") || u.RawPath != "" || strings.HasSuffix(u.Host, ":") {
		fail(400, "Use an HTTPS Kaneo URL without credentials or a fragment")
	}
	u.Host = strings.TrimSuffix(strings.ToLower(u.Host), ":443")
	p := strings.Split(u.Path, "/")
	if len(p) < 6 || p[0] != "" || p[1] != "dashboard" || p[2] != "workspace" || !kaneoID.MatchString(p[3]) || p[4] != "project" || !kaneoID.MatchString(p[5]) {
		fail(400, "Use a Kaneo workspace project URL")
	}
	return u, p
}

func kaneoProjectURL(value any) string {
	u, p := parseKaneoURL(value)
	if u == nil {
		return ""
	}
	if u.RawQuery != "" || u.ForceQuery || !(len(p) == 6 || len(p) == 7 && (p[6] == "board" || p[6] == "list" || p[6] == "overview")) {
		fail(400, "Use a Kaneo project board, list, or overview URL without a query")
	}
	u.Path = strings.Join(p[:6], "/") + "/board"
	if len(u.String()) > 2048 {
		fail(400, "Kaneo URL must be at most 2048 bytes after normalization")
	}
	return u.String()
}

func kaneoTaskURL(value any, projectURL string) string {
	u, p := parseKaneoURL(value)
	if u == nil {
		return ""
	}
	taskID := ""
	if len(p) == 8 && p[6] == "task" && u.RawQuery == "" && !u.ForceQuery {
		taskID = p[7]
	} else if len(p) == 7 && (p[6] == "board" || p[6] == "list") {
		query, err := url.ParseQuery(u.RawQuery)
		if err == nil && len(query) == 1 && len(query["taskId"]) == 1 {
			taskID = query.Get("taskId")
		}
	}
	if !kaneoID.MatchString(taskID) {
		fail(400, "Use a Kaneo task URL or a project board/list URL with taskId")
	}
	u.Path = strings.Join(p[:6], "/") + "/board"
	u.RawQuery, u.ForceQuery = "", false
	if projectURL == "" || u.String() != kaneoProjectURL(projectURL) {
		fail(400, "Kaneo task must belong to the repository's configured project")
	}
	u.Path = strings.Join(p[:6], "/") + "/task/" + taskID
	if len(u.String()) > 2048 {
		fail(400, "Kaneo URL must be at most 2048 bytes after normalization")
	}
	return u.String()
}

func (s *server) kaneoMerges(w http.ResponseWriter, r *http.Request, u, repo M) {
	requireUser(u)
	if r.Method != "GET" {
		fail(405, "Use GET")
	}
	query, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		fail(400, "Invalid query string")
	}
	after := uint64(0)
	if values, exists := query["after_id"]; exists {
		if len(values) != 1 {
			fail(400, "after_id must be one nonnegative integer")
		}
		after, err = strconv.ParseUint(values[0], 10, 63)
		if err != nil {
			fail(400, "after_id must be a nonnegative integer")
		}
	}
	rid := num(repo, "id")
	unlock := s.lockRepo(r, rid)
	defer unlock()
	repo = s.repo(r, rid, u, "read")
	s.reconcileMerges(repo)
	respond(w, 200, M{"pulls": s.rows("SELECT id,repo_id,state,kaneo_task_url FROM pull_requests WHERE repo_id=? AND state='merged' AND kaneo_task_url<>'' AND id>? ORDER BY id ASC LIMIT 100", rid, int64(after))})
}
