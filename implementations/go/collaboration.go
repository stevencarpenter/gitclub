package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func discussionText(b M, key string, required bool, limit int) string {
	v, exists := b[key]
	if !exists && !required {
		return ""
	}
	t, ok := v.(string)
	if !ok || len(t) > limit || (required && strings.TrimSpace(t) == "") || strings.ContainsRune(t, 0) {
		fail(400, fmt.Sprintf("%s must be %sstring of at most %d bytes", key, map[bool]string{true: "a nonempty ", false: "a "}[required], limit))
	}
	return t
}

func (s *server) pullRequest(repoID, id int64) M {
	x := s.one("SELECT d.*,u.username AS author FROM pull_requests d JOIN users u ON u.id=d.author_id WHERE d.repo_id=? AND d.id=?", repoID, id)
	if x == nil {
		fail(404, "Pull request not found")
	}
	return x
}

func (s *server) pullComments(id int64) []M {
	return s.rows("SELECT c.id,c.author_id,u.username AS author,c.body,c.path,c.line,c.commit_oid,c.created_at FROM comments c JOIN users u ON u.id=c.author_id WHERE c.target_type='pull' AND c.target_id=? ORDER BY c.id", id)
}

func (s *server) pullReviews(id int64) []M {
	return s.rows("SELECT r.id,r.author_id,u.username AS author,r.decision,r.body,r.commit_oid,r.created_at FROM reviews r JOIN users u ON u.id=r.author_id WHERE r.pull_id=? ORDER BY r.id", id)
}

func (s *server) pullTips(repo, pull M) (string, string, error) {
	base, err := s.resolve(repo, "refs/heads/"+str(pull, "base_branch"))
	if err != nil {
		return "", "", err
	}
	head, err := s.resolve(repo, "refs/heads/"+str(pull, "head_branch"))
	return base, head, err
}

// Return blockers and the simulated merge tree so the merge uses exactly the inspected tips.
func (s *server) pullBlockers(repo, pull M, base, head string) ([]string, string) {
	blockers := []string{}
	if str(pull, "state") != "open" {
		blockers = append(blockers, "Pull request is not open")
	}
	if base == "" || head == "" {
		return append(blockers, "Restore the missing base or head branch"), ""
	}
	if base == head {
		blockers = append(blockers, "Head has no changes to merge")
	}
	seen := map[int64]bool{}
	approved := false
	for _, review := range s.rows("SELECT * FROM reviews WHERE pull_id=? AND commit_oid=? AND decision<>'comment' ORDER BY id DESC", num(pull, "id"), head) {
		uid := num(review, "author_id")
		if seen[uid] {
			continue
		}
		seen[uid] = true
		if rank(s.role(repo, M{"id": uid})) < rank("write") {
			continue
		}
		if str(review, "decision") == "request_changes" {
			blockers = append(blockers, "A current reviewer has requested changes")
		}
		if str(review, "decision") == "approve" && uid != num(pull, "author_id") {
			approved = true
		}
	}
	if boolean(repo, "require_review") && !approved {
		blockers = append(blockers, "Approval of the current head by another writer is required")
	}
	tree, err := s.gitRun(num(repo, "id"), "merge-tree", "--write-tree", base, head)
	if err != nil {
		return append(blockers, "Resolve merge conflicts or incompatible branch history"), ""
	}
	return blockers, strings.TrimSpace(strings.SplitN(string(tree), "\n", 2)[0])
}

type mergeMarker struct {
	PullID     int64  `json:"pull_id"`
	BaseBranch string `json:"base_branch"`
	BaseOID    string `json:"base_oid"`
	CommitOID  string `json:"commit_oid"`
	UpdatedAt  int64  `json:"updated_at"`
}

func (s *server) markerPath(repoID, pullID int64) string {
	return filepath.Join(s.dataDir, "repos", fmt.Sprintf("%d.git", repoID), fmt.Sprintf("gitclub-merge-%d.json", pullID))
}

func durableMarker(path string, marker mergeMarker) (err error) {
	data, err := json.Marshal(marker)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = os.Remove(path)
		}
	}()
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	dir, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

// A durable intent survives ref-update success followed by metadata failure or process death.
// Reconciliation never rewrites Git history; the internal ref proves the transaction committed.
func (s *server) reconcileMerges(repo M) {
	paths, err := filepath.Glob(filepath.Join(s.dataDir, "repos", fmt.Sprintf("%d.git", num(repo, "id")), "gitclub-merge-*.json"))
	if err != nil {
		fail(500, "Cannot inspect merge recovery state")
	}
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			fail(503, "Merge recovery state cannot be read")
		}
		var marker mergeMarker
		if json.Unmarshal(data, &marker) != nil || marker.PullID <= 0 || !validBranch(marker.BaseBranch) || marker.CommitOID == "" {
			fail(503, "Merge recovery state requires operator inspection")
		}
		ledger, err := s.gitRun(num(repo, "id"), "for-each-ref", "--format=%(objectname)", fmt.Sprintf("refs/gitclub/merges/%d", marker.PullID))
		if err != nil {
			fail(503, "Cannot read merge transaction ledger")
		}
		if strings.TrimSpace(string(ledger)) == "" {
			if os.Remove(path) != nil {
				fail(503, "Cannot clear unapplied merge recovery state")
			}
			continue
		}
		if strings.TrimSpace(string(ledger)) != marker.CommitOID {
			fail(503, "Merge transaction ledger mismatch; inspect merge recovery state")
		}
		s.exec("UPDATE pull_requests SET state='merged',merged_oid=?,updated_at=? WHERE id=? AND repo_id=?", marker.CommitOID, marker.UpdatedAt, marker.PullID, num(repo, "id"))
		s.refresh(repo)
		if os.Remove(path) != nil {
			fail(503, "Merge recorded; recovery marker could not be cleared")
		}
	}
}

func (s *server) collaborationRoutes(w http.ResponseWriter, r *http.Request, u M, repo M, rest []string) bool {
	if len(rest) == 0 || rest[0] != "pulls" {
		return false
	}
	rid := num(repo, "id")
	var b M
	if r.Method != "GET" {
		b = body(r)
	}
	unlock := s.lockRepo(r, rid)
	defer unlock()
	// Settings and access may have changed while this request waited for the repository lock.
	repo = s.repo(r, rid, u, "read")
	s.reconcileMerges(repo)
	if r.Method != "GET" {
		if u == nil {
			fail(401, "Sign in to change pull requests")
		}
		if rank(s.role(repo, u)) < rank("write") {
			fail(403, "Repository write access required")
		}
	}
	if len(rest) == 1 {
		switch r.Method {
		case "GET":
			respond(w, 200, M{"pulls": s.rows("SELECT d.*,u.username AS author FROM pull_requests d JOIN users u ON u.id=d.author_id WHERE d.repo_id=? ORDER BY d.id DESC", rid)})
		case "POST":
			title := discussionText(b, "title", true, 240)
			content := discussionText(b, "body", false, 65536)
			taskURL := ""
			if value, exists := b["kaneo_task_url"]; exists {
				taskURL = kaneoTaskURL(value, str(repo, "kaneo_project_url"))
			}
			t := now()
			base := str(b, "base_branch")
			if base == "" {
				base = str(repo, "default_branch")
			}
			head := str(b, "head_branch")
			if !validBranch(base) || !validBranch(head) || base == head {
				fail(400, "Choose distinct valid base and head branches")
			}
			baseOID, headOID, err := s.pullTips(repo, M{"base_branch": base, "head_branch": head})
			if err != nil {
				fail(400, "Both branches must exist")
			}
			changed, err := s.gitRun(rid, "diff", "--no-ext-diff", "--no-textconv", "--name-only", baseOID+"..."+headOID, "--")
			if err != nil || len(changed) == 0 {
				fail(409, "Head branch must contain changes relative to base")
			}
			id := s.insert("INSERT INTO pull_requests(repo_id,author_id,title,body,base_branch,head_branch,kaneo_task_url,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)", rid, num(u, "id"), title, content, base, head, taskURL, t, t)
			respond(w, 201, M{"pull": s.pullRequest(rid, id)})
		default:
			fail(405, "Method not allowed")
		}
		return true
	}
	id, err := strconv.ParseInt(rest[1], 10, 64)
	if err != nil || id <= 0 {
		fail(404, "Pull request not found")
	}
	d := s.pullRequest(rid, id)
	if len(rest) == 2 {
		switch r.Method {
		case "GET":
			result := M{"pull": d, "comments": s.pullComments(id)}
			base, head, _ := s.pullTips(repo, d)
			blockers, _ := s.pullBlockers(repo, d, base, head)
			if str(d, "state") == "merged" {
				baseRaw, _ := s.gitRun(rid, "rev-parse", "--verify", str(d, "merged_oid")+"^1^{commit}")
				headRaw, _ := s.gitRun(rid, "rev-parse", "--verify", str(d, "merged_oid")+"^2^{commit}")
				base, head = strings.TrimSpace(string(baseRaw)), strings.TrimSpace(string(headRaw))
			}
			diff := []byte{}
			if base != "" && head != "" {
				diff, _ = s.gitRun(rid, "diff", "--no-ext-diff", "--no-textconv", base+"..."+head, "--")
			}
			truncated := len(diff) > 1<<20
			if truncated {
				diff = diff[:1<<20]
			}
			result["reviews"], result["diff"], result["base_oid"], result["head_oid"], result["truncated"], result["mergeable"], result["merge_blockers"] = s.pullReviews(id), string(diff), base, head, truncated, len(blockers) == 0, blockers
			respond(w, 200, result)
		case "PATCH":
			if num(d, "author_id") != num(u, "id") && s.role(repo, u) != "admin" {
				fail(403, "Only the author or repository admin can edit this pull request")
			}
			if str(d, "state") == "merged" {
				fail(409, "Merged pull requests cannot be edited")
			}
			title, content, state := str(d, "title"), str(d, "body"), str(d, "state")
			taskURL := str(d, "kaneo_task_url")
			if _, ok := b["title"]; ok {
				title = discussionText(b, "title", true, 240)
			}
			if _, ok := b["body"]; ok {
				content = discussionText(b, "body", false, 65536)
			}
			if _, ok := b["state"]; ok {
				state = str(b, "state")
				if state != "open" && state != "closed" {
					fail(400, "State must be open or closed")
				}
			}
			if value, exists := b["kaneo_task_url"]; exists {
				taskURL = kaneoTaskURL(value, str(repo, "kaneo_project_url"))
			}
			s.exec("UPDATE pull_requests SET title=?,body=?,state=?,kaneo_task_url=?,updated_at=? WHERE id=?", title, content, state, taskURL, now(), id)
			respond(w, 200, M{"pull": s.pullRequest(rid, id)})
		default:
			fail(405, "Method not allowed")
		}
		return true
	}
	if len(rest) != 3 {
		fail(404, "Route not found")
	}
	if r.Method != "POST" {
		fail(405, "Method not allowed")
	}
	switch rest[2] {
	case "comments":
		content := discussionText(b, "body", true, 65536)
		path, oid := discussionText(b, "path", false, 4096), discussionText(b, "commit_oid", false, 64)
		line := int64(0)
		if value, exists := b["line"]; exists {
			number, ok := value.(json.Number)
			if !ok {
				fail(400, "Comment line must be an integer")
			}
			var err error
			line, err = number.Int64()
			if err != nil {
				fail(400, "Comment line must be an integer")
			}
		}
		if line < 0 || strings.ContainsAny(path, "\x00\r\n\\") || strings.HasPrefix(path, "/") || strings.Contains("/"+path+"/", "/../") || strings.Contains("/"+path+"/", "/./") {
			fail(400, "Comment location is invalid")
		}
		if path != "" || oid != "" || line != 0 {
			if path == "" || line <= 0 || oid == "" {
				fail(400, "Inline comments require a file path, positive line, and current head commit_oid")
			}
			_, head, err := s.pullTips(repo, d)
			if err != nil || oid != head {
				fail(409, "Head changed; reload the diff before commenting")
			}
			blob, err := s.gitRun(rid, "cat-file", "blob", head+":"+path)
			if err != nil {
				fail(400, "Comment path must name a file at the current head")
			}
			if line > int64(strings.Count(string(blob), "\n")+1) {
				fail(400, "Comment line is outside the file")
			}
		}
		cid := s.insert("INSERT INTO comments(repo_id,target_type,target_id,author_id,body,path,line,commit_oid,created_at) VALUES(?,'pull',?,?,?,?,?,?,?)", rid, id, num(u, "id"), content, path, line, oid, now())
		respond(w, 201, M{"comment": s.one("SELECT c.id,c.author_id,u.username AS author,c.body,c.path,c.line,c.commit_oid,c.created_at FROM comments c JOIN users u ON u.id=c.author_id WHERE c.id=?", cid)})
	case "reviews":
		if str(d, "state") != "open" {
			fail(409, "Only open pull requests can be reviewed")
		}
		decision := str(b, "decision")
		if decision != "approve" && decision != "request_changes" && decision != "comment" {
			fail(400, "Decision must be approve, request_changes, or comment")
		}
		if decision == "approve" && num(d, "author_id") == num(u, "id") {
			fail(403, "Authors cannot approve their own pull requests")
		}
		content := discussionText(b, "body", false, 65536)
		_, head, err := s.pullTips(repo, d)
		if err != nil {
			fail(409, "Restore the pull request branches before reviewing")
		}
		if expected := str(b, "expected_head_oid"); expected == "" {
			fail(400, "expected_head_oid is required to review the displayed commit")
		} else if expected != head {
			fail(409, "Head changed; reload and review the current diff")
		}
		reviewID := s.insert("INSERT INTO reviews(pull_id,author_id,decision,body,commit_oid,created_at) VALUES(?,?,?,?,?,?)", id, num(u, "id"), decision, content, head, now())
		respond(w, 201, M{"review": s.one("SELECT r.id,r.author_id,u.username AS author,r.decision,r.body,r.commit_oid,r.created_at FROM reviews r JOIN users u ON u.id=r.author_id WHERE r.id=?", reviewID)})
	case "merge":
		base, head, err := s.pullTips(repo, d)
		if err != nil {
			fail(409, "Restore the pull request branches before merging")
		}
		if str(b, "expected_head_oid") != head {
			fail(409, "Head changed; reload and review the current diff")
		}
		blockers, tree := s.pullBlockers(repo, d, base, head)
		if len(blockers) > 0 {
			fail(409, strings.Join(blockers, "; "))
		}
		commit, err := s.gitRun(rid, "-c", "user.name="+str(u, "username"), "-c", "user.email="+str(u, "username")+"@gitclub.local", "commit-tree", tree, "-p", base, "-p", head, "-m", fmt.Sprintf("Merge pull request #%d: %s", id, str(d, "title")))
		if err != nil {
			fail(500, "Could not create merge commit; branches were unchanged")
		}
		oid := strings.TrimSpace(string(commit))
		marker := mergeMarker{id, str(d, "base_branch"), base, oid, now()}
		markerPath := s.markerPath(rid, id)
		if durableMarker(markerPath, marker) != nil {
			fail(503, "Cannot persist merge recovery state; branches were unchanged")
		}
		transaction := fmt.Sprintf("start\nverify refs/heads/%s %s\nupdate refs/heads/%s %s %s\ncreate refs/gitclub/merges/%d %s\nprepare\ncommit\n", str(d, "head_branch"), head, str(d, "base_branch"), oid, base, id, oid)
		if _, err = s.gitRunInput(rid, transaction, "update-ref", "--stdin"); err != nil {
			// A killed subprocess may already have committed its ref transaction.
			// Reconcile instead of discarding the intent on an ambiguous failure.
			s.reconcileMerges(repo)
			if recorded := s.pullRequest(rid, id); str(recorded, "merged_oid") == oid {
				respond(w, 200, M{"pull": recorded, "commit_oid": oid})
				return true
			}
			fail(409, "Base or head changed during merge; reload and try again")
		}
		s.reconcileMerges(repo)
		respond(w, 200, M{"pull": s.pullRequest(rid, id), "commit_oid": oid})
	default:
		fail(404, "Route not found")
	}
	return true
}
