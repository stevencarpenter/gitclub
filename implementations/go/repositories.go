package main

import (
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

func (s *server) role(repo, u M) string {
	best := ""
	if str(repo, "visibility") == "public" {
		best = "read"
	}
	if u == nil {
		return best
	}
	for _, r := range s.rows("SELECT role FROM namespace_members WHERE namespace=? AND user_id=? UNION ALL SELECT role FROM repo_members WHERE repo_id=? AND user_id=?", str(repo, "owner"), num(u, "id"), num(repo, "id"), num(u, "id")) {
		if rank(str(r, "role")) > rank(best) {
			best = str(r, "role")
		}
	}
	return best
}
func (s *server) repo(r *http.Request, id int64, u M, minRole string) M {
	repo := s.one("SELECT * FROM repositories WHERE id=?", id)
	if repo == nil {
		fail(404, "Repository not found")
	}
	role := s.role(repo, u)
	if rank(role) == 0 {
		fail(404, "Repository not found")
	}
	if rank(role) < rank(minRole) {
		if u == nil {
			fail(401, "Sign in to continue")
		}
		fail(403, "Repository "+minRole+" permission required")
	}
	return repo
}
func (s *server) repositoryView(repo, u M) M {
	v := M{}
	for _, k := range []string{"id", "owner", "name", "description", "visibility", "default_branch", "created_at", "updated_at"} {
		v[k] = repo[k]
	}
	v["full_name"] = str(repo, "owner") + "/" + str(repo, "name")
	v["require_review"] = boolean(repo, "require_review")
	v["role"] = s.role(repo, u)
	v["pinned"] = u != nil && s.one("SELECT 1 FROM pins WHERE repo_id=? AND user_id=?", num(repo, "id"), num(u, "id")) != nil
	return v
}
func parseID(text string) int64 {
	id, e := strconv.ParseInt(text, 10, 64)
	if e != nil || id <= 0 {
		fail(404, "Resource not found")
	}
	return id
}
func (s *server) namespaces(w http.ResponseWriter, r *http.Request, u M, rest []string) {
	requireUser(u)
	if len(rest) == 0 {
		if r.Method == "GET" {
			respond(w, 200, M{"namespaces": s.rows("SELECT namespaces.name,kind,role FROM namespaces JOIN namespace_members ON namespace=name WHERE user_id=? ORDER BY name", num(u, "id"))})
			return
		}
		if r.Method == "POST" {
			b := body(r)
			name := str(b, "name")
			if !nameOK(name) {
				fail(400, "Use a lowercase namespace name of 1 to 63 characters")
			}
			tx, e := s.db.Begin()
			if e != nil {
				fail(500, "Database operation failed")
			}
			defer tx.Rollback()
			if _, e = tx.Exec("INSERT INTO namespaces(name,kind) VALUES(?,'organization')", name); e != nil {
				fail(409, "Namespace already exists")
			}
			if _, e = tx.Exec("INSERT INTO namespace_members(namespace,user_id,role) VALUES(?,?,'admin')", name, num(u, "id")); e != nil {
				fail(500, "Namespace creation failed")
			}
			if tx.Commit() != nil {
				fail(500, "Namespace creation failed")
			}
			respond(w, 201, M{"namespace": M{"name": name, "kind": "organization", "role": "admin"}})
			return
		}
	}
	if len(rest) == 2 && rest[1] == "members" && r.Method == "POST" {
		membership := s.one("SELECT role FROM namespace_members WHERE namespace=? AND user_id=?", rest[0], num(u, "id"))
		if str(membership, "role") != "admin" {
			fail(403, "Namespace admin permission required")
		}
		ns := s.one("SELECT kind FROM namespaces WHERE name=?", rest[0])
		if str(ns, "kind") == "user" {
			fail(403, "Use repository memberships to share a personal namespace")
		}
		b := body(r)
		target := s.one("SELECT id FROM users WHERE username=?", str(b, "username"))
		if target == nil || rank(str(b, "role")) == 0 {
			fail(400, "Provide an existing username and admin, write, or read role")
		}
		if num(target, "id") == num(u, "id") && str(b, "role") != "admin" {
			fail(409, "Cannot remove your own namespace admin role")
		}
		s.exec("INSERT INTO namespace_members(namespace,user_id,role) VALUES(?,?,?) ON CONFLICT(namespace,user_id) DO UPDATE SET role=excluded.role", rest[0], num(target, "id"), str(b, "role"))
		respond(w, 200, M{"ok": true})
		return
	}
	fail(404, "Endpoint not found")
}
func (s *server) repositories(w http.ResponseWriter, r *http.Request, u M, rest []string) {
	if len(rest) == 0 {
		switch r.Method {
		case "GET":
			var group M
			if value := r.URL.Query().Get("group"); value != "" {
				group = s.group(parseID(value), u, false)
			}
			out := []M{}
			q := strings.ToLower(r.URL.Query().Get("q"))
			owner := r.URL.Query().Get("owner")
			for _, repo := range s.rows("SELECT * FROM repositories") {
				if rank(s.role(repo, u)) == 0 || owner != "" && str(repo, "owner") != owner {
					continue
				}
				if q != "" && !strings.Contains(strings.ToLower(str(repo, "owner")+"/"+str(repo, "name")+" "+str(repo, "description")), q) {
					continue
				}
				if group != nil && s.one("SELECT 1 FROM group_repos WHERE group_id=? AND repo_id=?", num(group, "id"), num(repo, "id")) == nil {
					continue
				}
				out = append(out, s.repositoryView(s.refresh(repo), u))
			}
			sort.Slice(out, func(i, j int) bool {
				if boolean(out[i], "pinned") != boolean(out[j], "pinned") {
					return boolean(out[i], "pinned")
				}
				if num(out[i], "updated_at") != num(out[j], "updated_at") {
					return num(out[i], "updated_at") > num(out[j], "updated_at")
				}
				return num(out[i], "id") < num(out[j], "id")
			})
			respond(w, 200, M{"repositories": out})
			return
		case "POST":
			requireUser(u)
			b := body(r)
			owner, name := str(b, "owner"), str(b, "name")
			if !nameOK(owner) || !nameOK(name) || strings.HasSuffix(name, ".git") {
				fail(400, "Use lowercase owner/repository names, without .git suffix")
			}
			membership := s.one("SELECT role FROM namespace_members WHERE namespace=? AND user_id=?", owner, num(u, "id"))
			if rank(str(membership, "role")) < 2 {
				fail(403, "Namespace write permission required")
			}
			visibility := str(b, "visibility")
			if visibility == "" {
				visibility = "private"
			}
			if visibility != "private" && visibility != "public" {
				fail(400, "Visibility must be private or public")
			}
			branch := str(b, "default_branch")
			if branch == "" {
				branch = "main"
			}
			if !validBranch(branch) {
				fail(400, "Invalid default branch")
			}
			description := str(b, "description")
			if len(description) > 4096 {
				fail(400, "Description exceeds 4096 bytes")
			}
			timestamp := now()
			id := s.exec("INSERT INTO repositories(owner,name,description,visibility,default_branch,created_at,updated_at) VALUES(?,?,?,?,?,?,?)", owner, name, description, visibility, branch, timestamp, timestamp)
			repo := s.one("SELECT * FROM repositories WHERE id=?", id)
			if e := s.initializeRepo(repo); e != nil {
				s.exec("DELETE FROM repositories WHERE id=?", id)
				os.RemoveAll(filepath.Join(s.dataDir, "repos", strconv.FormatInt(id, 10)+".git"))
				fail(500, "Git repository initialization failed")
			}
			respond(w, 201, M{"repository": s.repositoryView(repo, u)})
			return
		}
		fail(405, "Use GET or POST")
	}
	id := parseID(rest[0])
	repo := s.repo(r, id, u, "read")
	if len(rest) == 1 {
		switch r.Method {
		case "GET":
			respond(w, 200, M{"repository": s.repositoryView(s.refresh(repo), u)})
			return
		case "PATCH":
			s.repo(r, id, u, "admin")
			b := body(r)
			unlock := s.lockRepo(r, id)
			defer unlock()
			repo = s.one("SELECT * FROM repositories WHERE id=?", id)
			for key := range b {
				switch key {
				case "description":
					v, ok := b[key].(string)
					if !ok || len(v) > 4096 {
						fail(400, "Description must be text of at most 4096 bytes")
					}
					repo[key] = v
				case "visibility":
					v := str(b, key)
					if v != "private" && v != "public" {
						fail(400, "Visibility must be private or public")
					}
					repo[key] = v
				case "require_review":
					v, ok := b[key].(bool)
					if !ok {
						fail(400, "require_review must be boolean")
					}
					repo[key] = v
				case "default_branch":
					v := str(b, key)
					if !validBranch(v) {
						fail(400, "Invalid default branch")
					}
					repo[key] = v
				default:
					fail(400, "Unsupported repository field")
				}
			}
			if _, ok := b["default_branch"]; ok {
				if _, e := s.gitRun(id, "symbolic-ref", "HEAD", "refs/heads/"+str(repo, "default_branch")); e != nil {
					fail(500, "Default branch update failed")
				}
				oid, _ := s.resolve(repo, str(repo, "default_branch"))
				repo["default_oid"] = oid
				repo["updated_at"] = now()
			}
			s.exec("UPDATE repositories SET description=?,visibility=?,default_branch=?,require_review=?,updated_at=?,default_oid=? WHERE id=?", str(repo, "description"), str(repo, "visibility"), str(repo, "default_branch"), boolean(repo, "require_review"), num(repo, "updated_at"), str(repo, "default_oid"), id)
			respond(w, 200, M{"repository": s.repositoryView(repo, u)})
			return
		}
		fail(405, "Use GET or PATCH")
	}
	if len(rest) == 2 && rest[1] == "pin" && r.Method == "POST" {
		requireUser(u)
		b := body(r)
		pinned, ok := b["pinned"].(bool)
		if !ok {
			fail(400, "pinned must be boolean")
		}
		if pinned {
			s.exec("INSERT OR IGNORE INTO pins(repo_id,user_id) VALUES(?,?)", id, num(u, "id"))
		} else {
			s.exec("DELETE FROM pins WHERE repo_id=? AND user_id=?", id, num(u, "id"))
		}
		respond(w, 200, M{"ok": true})
		return
	}
	if len(rest) == 2 && rest[1] == "members" && r.Method == "POST" {
		s.repo(r, id, u, "admin")
		b := body(r)
		target := s.one("SELECT id FROM users WHERE username=?", str(b, "username"))
		if target == nil || rank(str(b, "role")) == 0 {
			fail(400, "Provide an existing username and admin, write, or read role")
		}
		s.exec("INSERT INTO repo_members(repo_id,user_id,role) VALUES(?,?,?) ON CONFLICT(repo_id,user_id) DO UPDATE SET role=excluded.role", id, num(target, "id"), str(b, "role"))
		respond(w, 200, M{"ok": true})
		return
	}
	if s.gitRoutes(w, r, u, repo, rest[1:]) || s.collaborationRoutes(w, r, u, repo, rest[1:]) {
		return
	}
	fail(404, "Endpoint not found")
}
func (s *server) group(id int64, u M, edit bool) M {
	requireUser(u)
	g := s.one("SELECT * FROM groups WHERE id=?", id)
	if g == nil || num(g, "creator_id") != num(u, "id") && !boolean(g, "shared") {
		fail(404, "Group not found")
	}
	if edit && num(g, "creator_id") != num(u, "id") {
		fail(403, "Only the group creator can edit it")
	}
	return g
}
func (s *server) groupView(g, u M) M {
	ids := []int64{}
	for _, repo := range s.rows("SELECT repositories.* FROM repositories JOIN group_repos ON repo_id=repositories.id WHERE group_id=? ORDER BY updated_at DESC,repositories.id", num(g, "id")) {
		if rank(s.role(repo, u)) > 0 {
			ids = append(ids, num(repo, "id"))
		}
	}
	return M{"id": g["id"], "name": g["name"], "creator_id": g["creator_id"], "shared": boolean(g, "shared"), "repo_ids": ids}
}
func (s *server) groups(w http.ResponseWriter, r *http.Request, u M, rest []string) {
	requireUser(u)
	if len(rest) == 0 {
		if r.Method == "GET" {
			out := []M{}
			for _, g := range s.rows("SELECT * FROM groups WHERE creator_id=? OR shared=1 ORDER BY name,id", num(u, "id")) {
				out = append(out, s.groupView(g, u))
			}
			respond(w, 200, M{"groups": out})
			return
		}
		if r.Method == "POST" {
			b := body(r)
			name := strings.TrimSpace(str(b, "name"))
			if len(name) < 1 || len([]rune(name)) > 80 {
				fail(400, "Group name must have 1 to 80 characters")
			}
			shared := false
			if v, exists := b["shared"]; exists {
				var ok bool
				shared, ok = v.(bool)
				if !ok {
					fail(400, "shared must be boolean")
				}
			}
			id := s.exec("INSERT INTO groups(name,creator_id,shared,created_at) VALUES(?,?,?,?)", name, num(u, "id"), shared, now())
			respond(w, 201, M{"group": s.groupView(s.group(id, u, false), u)})
			return
		}
	}
	if len(rest) != 1 {
		fail(404, "Endpoint not found")
	}
	id := parseID(rest[0])
	g := s.group(id, u, true)
	if r.Method == "DELETE" {
		s.exec("DELETE FROM groups WHERE id=?", id)
		respond(w, 200, M{"ok": true})
		return
	}
	if r.Method == "PATCH" {
		b := body(r)
		if _, exists := b["name"]; exists {
			v := strings.TrimSpace(str(b, "name"))
			if len(v) < 1 || len([]rune(v)) > 80 {
				fail(400, "Group name must have 1 to 80 characters")
			}
			g["name"] = v
		}
		shared := boolean(g, "shared")
		if v, exists := b["shared"]; exists {
			var ok bool
			shared, ok = v.(bool)
			if !ok {
				fail(400, "shared must be boolean")
			}
		}
		ids := []int64{}
		_, replace := b["repo_ids"]
		if replace {
			values, ok := b["repo_ids"].([]any)
			if !ok || len(values) > 1000 {
				fail(400, "repo_ids must contain at most 1000 repository IDs")
			}
			for _, value := range values {
				id := num(M{"id": value}, "id")
				if id <= 0 {
					fail(400, "Invalid repository ID")
				}
				s.repo(r, id, u, "read")
				ids = append(ids, id)
			}
		}
		tx, e := s.db.Begin()
		if e != nil {
			fail(500, "Database operation failed")
		}
		defer tx.Rollback()
		if _, e = tx.Exec("UPDATE groups SET name=?,shared=? WHERE id=?", str(g, "name"), shared, id); e != nil {
			fail(500, "Group update failed")
		}
		if replace {
			if _, e = tx.Exec("DELETE FROM group_repos WHERE group_id=?", id); e != nil {
				fail(500, "Group update failed")
			}
			for _, repoID := range ids {
				if _, e = tx.Exec("INSERT OR IGNORE INTO group_repos(group_id,repo_id) VALUES(?,?)", id, repoID); e != nil {
					fail(500, "Group update failed")
				}
			}
		}
		if tx.Commit() != nil {
			fail(500, "Group update failed")
		}
		respond(w, 200, M{"group": s.groupView(s.group(id, u, false), u)})
		return
	}
	fail(405, "Use PATCH or DELETE")
}
