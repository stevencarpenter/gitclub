package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
)

var oidPattern = regexp.MustCompile(`^[0-9a-f]{40}([0-9a-f]{24})?$`)
var sshCommandPattern = regexp.MustCompile(`^(git-upload-pack|git-receive-pack) '([a-z0-9][a-z0-9._-]{0,62})/([a-z0-9][a-z0-9._-]{0,62})\.git'$`)

func safeGitEnv() []string {
	return []string{"PATH=" + os.Getenv("PATH"), "HOME=/nonexistent", "LANG=C.UTF-8", "LC_ALL=C", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_TERMINAL_PROMPT=0", "GIT_NO_REPLACE_OBJECTS=1"}
}
func validBranch(ref string) bool {
	if ref == "" || len(ref) > 255 || strings.HasPrefix(ref, "-") || strings.ContainsAny(ref, "\x00\n\r") {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", "check-ref-format", "--branch", ref)
	cmd.Env = safeGitEnv()
	return cmd.Run() == nil
}
func validGitPath(p string) bool {
	return !strings.ContainsAny(p, "\x00\r\n\\") && !strings.HasPrefix(p, "/") && (p == "" || path.Clean(p) == p && p != ".." && !strings.HasPrefix(p, "../"))
}
func (s *server) repoPath(id int64) string {
	return filepath.Join(s.dataDir, "repos", strconv.FormatInt(id, 10)+".git")
}
func (s *server) repoLock(id int64) *sync.Mutex {
	v, _ := s.repoLocks.LoadOrStore(id, &sync.Mutex{})
	return v.(*sync.Mutex)
}

type cappedOutput struct {
	bytes.Buffer
	cap       int
	truncated bool
}

// Override the embedded Buffer fast path so io.Copy cannot bypass the cap.
func (b *cappedOutput) ReadFrom(r io.Reader) (int64, error) {
	return io.Copy(struct{ io.Writer }{b}, r)
}

func (b *cappedOutput) Write(p []byte) (int, error) {
	n := len(p)
	remain := b.cap - b.Len()
	if n > remain {
		b.truncated = true
		p = p[:remain]
	}
	_, _ = b.Buffer.Write(p)
	return n, nil
}

func (s *server) gitRead(id int64, limit int, extraEnv []string, args ...string) ([]byte, bool, error) {
	return s.gitReadInput(id, limit, extraEnv, "", args...)
}
func (s *server) gitReadInput(id int64, limit int, extraEnv []string, input string, args ...string) ([]byte, bool, error) {
	return s.gitReadWaiting(id, limit, extraEnv, input, false, args...)
}
func (s *server) gitReadWaiting(id int64, limit int, extraEnv []string, input string, wait bool, args ...string) ([]byte, bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if wait {
		select {
		case s.gitSlots <- struct{}{}:
		case <-ctx.Done():
			return nil, false, ctx.Err()
		}
	} else {
		select {
		case s.gitSlots <- struct{}{}:
		default:
			return nil, false, errors.New("git capacity exhausted")
		}
	}
	defer func() { <-s.gitSlots }()
	argv := append([]string{"--git-dir=" + s.repoPath(id), "-c", "core.quotepath=false", "-c", "diff.external=", "-c", "protocol.file.allow=never", "-c", "protocol.ext.allow=never"}, args...)
	cmd := exec.CommandContext(ctx, "git", argv...)
	cmd.Env = append(safeGitEnv(), extraEnv...)
	cmd.Stdin = strings.NewReader(input)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = time.Second
	out := &cappedOutput{cap: limit}
	cmd.Stdout = out
	cmd.Stderr = io.Discard
	err := cmd.Run()
	return out.Bytes(), out.truncated, err
}
func (s *server) gitRun(id int64, args ...string) ([]byte, error) {
	b, truncated, e := s.gitRead(id, 2<<20, nil, args...)
	if truncated && e == nil {
		e = errors.New("git result too large")
	}
	return b, e
}
func (s *server) gitRunInput(id int64, input string, args ...string) ([]byte, error) {
	b, truncated, e := s.gitReadInput(id, 2<<20, nil, input, args...)
	if truncated && e == nil {
		e = errors.New("git result too large")
	}
	return b, e
}
func (s *server) resolve(repo M, ref string) (string, error) {
	if ref == "" {
		ref = str(repo, "default_branch")
	}
	if !(oidPattern.MatchString(ref) || validBranch(ref)) || strings.Contains(ref, "@{") {
		return "", errors.New("invalid ref")
	}
	out, err := s.gitRun(num(repo, "id"), "rev-parse", "--verify", "--end-of-options", ref+"^{commit}")
	if err != nil {
		return "", errors.New("ref does not identify a commit")
	}
	oid := strings.TrimSpace(string(out))
	if !oidPattern.MatchString(oid) {
		return "", errors.New("invalid object")
	}
	return oid, nil
}

// GitClub initializes the native files ref backend. Bound disk reads and follow
// symbolic refs without spawning Git for every repository in the directory.
func safeStoredRef(ref string) bool {
	if !strings.HasPrefix(ref, "refs/") || len(ref) > 1024 || strings.Contains(ref, "..") || strings.Contains(ref, "@{") || strings.ContainsAny(ref, "\\~^:?*[") {
		return false
	}
	for _, c := range ref {
		if c <= ' ' || c == 127 {
			return false
		}
	}
	for _, part := range strings.Split(ref, "/") {
		if part == "" || strings.HasPrefix(part, ".") || strings.HasSuffix(part, ".") || strings.HasSuffix(part, ".lock") {
			return false
		}
	}
	return true
}
func boundedRefFile(name string, maximum int64) ([]byte, error) {
	f, err := os.Open(name)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > maximum {
		return nil, errors.New("invalid reference file")
	}
	data, err := io.ReadAll(io.LimitReader(f, maximum+1))
	if err != nil || int64(len(data)) > maximum {
		return nil, errors.New("reference read failed")
	}
	return data, nil
}
func (s *server) defaultOID(repo M) (string, error) {
	root := s.repoPath(num(repo, "id"))
	ref := "refs/heads/" + str(repo, "default_branch")
	seen := map[string]bool{}
	for depth := 0; depth < 8; depth++ {
		if !safeStoredRef(ref) || seen[ref] {
			return "", errors.New("invalid symbolic reference")
		}
		seen[ref] = true
		filename := filepath.Join(root, filepath.FromSlash(ref))
		info, err := os.Lstat(filename)
		if err == nil && info.Mode()&os.ModeSymlink != 0 {
			return "", errors.New("filesystem symlink reference unsupported")
		}
		if err != nil && !os.IsNotExist(err) {
			return "", err
		}
		raw, err := boundedRefFile(filename, 1024)
		if err == nil {
			value := strings.TrimSpace(string(raw))
			if strings.HasPrefix(value, "ref: ") {
				ref = strings.TrimPrefix(value, "ref: ")
				continue
			}
			if oidPattern.MatchString(value) && strings.Trim(value, "0") != "" {
				return value, nil
			}
			return "", errors.New("invalid reference object ID")
		}
		if !os.IsNotExist(err) {
			return "", err
		}
		// A missing loose ref is normal for empty repositories and git pack-refs.
		packed, err := boundedRefFile(filepath.Join(root, "packed-refs"), 8<<20)
		if err != nil {
			return "", err
		}
		for _, line := range strings.Split(string(packed), "\n") {
			if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, "^") {
				continue
			}
			oid, name, ok := strings.Cut(line, " ")
			if !ok || !oidPattern.MatchString(oid) || !safeStoredRef(name) {
				return "", errors.New("invalid packed reference")
			}
			if name == ref {
				if strings.Trim(oid, "0") == "" {
					return "", errors.New("invalid packed object ID")
				}
				return oid, nil
			}
		}
		return "", os.ErrNotExist
	}
	return "", errors.New("symbolic reference depth exceeded")
}
func (s *server) refresh(repo M) M {
	// A missing post-receive notification is reconciled against the real default tip.
	oid, err := s.defaultOID(repo)
	if err != nil {
		return repo
	}
	current := s.one("SELECT default_oid,updated_at FROM repositories WHERE id=?", num(repo, "id"))
	if current == nil {
		return repo
	}
	if str(current, "default_oid") != oid {
		stamp := now()
		s.exec("UPDATE repositories SET default_oid=?,updated_at=? WHERE id=? AND default_oid<>?", oid, stamp, num(repo, "id"), oid)
		repo["updated_at"] = stamp
	} else {
		repo["updated_at"] = current["updated_at"]
	}
	repo["default_oid"] = oid
	return repo
}
func (s *server) initializeRepo(repo M) error {
	id := num(repo, "id")
	if !validBranch(str(repo, "default_branch")) {
		return errors.New("invalid default branch")
	}
	if err := os.MkdirAll(filepath.Join(s.dataDir, "repos"), 0700); err != nil {
		return err
	}
	if _, err := s.gitRun(id, "init", "--bare", s.repoPath(id)); err != nil {
		return err
	}
	if _, err := s.gitRun(id, "symbolic-ref", "HEAD", "refs/heads/"+str(repo, "default_branch")); err != nil {
		return err
	}
	if _, err := s.gitRun(id, "config", "http.receivepack", "true"); err != nil {
		return err
	}
	if _, err := s.gitRun(id, "config", "transfer.hideRefs", "refs/gitclub/"); err != nil {
		return err
	}
	hook, err := os.ReadFile(filepath.Join(s.sharedDir, "git-hook.py"))
	if err != nil {
		return err
	}
	for _, name := range []string{"pre-receive", "post-receive"} {
		if err := os.WriteFile(filepath.Join(s.repoPath(id), "hooks", name), hook, 0700); err != nil {
			return err
		}
	}
	return nil
}
func (s *server) gitRoutes(w http.ResponseWriter, r *http.Request, u M, repo M, rest []string) bool {
	if len(rest) == 2 && rest[0] == "git" && r.Method == "POST" {
		s.gitHook(w, r, u, repo, rest[1])
		return true
	}
	if len(rest) != 1 || r.Method != "GET" {
		return false
	}
	id := num(repo, "id")
	q := r.URL.Query()
	ref := q.Get("ref")
	if ref == "" {
		ref = str(repo, "default_branch")
	}
	switch rest[0] {
	case "branches":
		out, e := s.gitRun(id, "for-each-ref", "--format=%(refname:short)%09%(objectname)", "refs/heads")
		if e != nil {
			fail(503, "Cannot read branches; retry shortly")
		}
		branches := []M{}
		for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
			p := strings.SplitN(line, "\t", 2)
			if len(p) == 2 {
				branches = append(branches, M{"name": p[0], "oid": p[1]})
			}
		}
		respond(w, 200, M{"branches": branches, "default_branch": repo["default_branch"]})
	case "tree", "blob", "commits":
		oid, e := s.resolve(repo, ref)
		if e != nil {
			heads, he := s.gitRun(id, "for-each-ref", "--count=1", "refs/heads")
			if he == nil && len(heads) == 0 && rest[0] != "blob" {
				if rest[0] == "tree" {
					respond(w, 200, M{"entries": []M{}, "ref": ref})
				} else {
					respond(w, 200, M{"commits": []M{}})
				}
				return true
			}
			fail(400, "Ref does not identify an existing commit")
		}
		p := q.Get("path")
		if !validGitPath(p) {
			fail(400, "Invalid repository path")
		}
		if rest[0] == "commits" {
			out, err := s.gitRun(id, "log", "-50", "--format=%H%x00%h%x00%s%x00%an%x00%aI%x00", oid, "--")
			if err != nil {
				fail(503, "Cannot read commits")
			}
			commits := []M{}
			fields := strings.Split(string(out), "\x00")
			for i := 0; i+4 < len(fields); i += 5 {
				commits = append(commits, M{"oid": strings.TrimSpace(fields[i]), "short_oid": fields[i+1], "subject": fields[i+2], "author": fields[i+3], "date": fields[i+4]})
			}
			respond(w, 200, M{"commits": commits})
			return true
		}
		if rest[0] == "tree" {
			target := oid
			if p != "" {
				target += ":" + p
			}
			out, err := s.gitRun(id, "ls-tree", "-z", "-l", target)
			if err != nil {
				fail(404, "Directory not found")
			}
			entries := []M{}
			for _, entry := range strings.Split(string(out), "\x00") {
				v := strings.SplitN(entry, "\t", 2)
				if len(v) != 2 {
					continue
				}
				meta := strings.Fields(v[0])
				if len(meta) != 4 {
					continue
				}
				kind := "file"
				if meta[1] == "tree" {
					kind = "directory"
				}
				size, _ := strconv.ParseInt(meta[3], 10, 64)
				entries = append(entries, M{"name": v[1], "path": path.Join(p, v[1]), "type": kind, "size": size})
			}
			respond(w, 200, M{"entries": entries, "ref": ref})
			return true
		}
		if p == "" {
			fail(400, "A file path is required")
		}
		object := oid + ":" + p
		sz, e := s.gitRun(id, "cat-file", "-s", object)
		if e != nil {
			fail(404, "File not found")
		}
		size, _ := strconv.ParseInt(strings.TrimSpace(string(sz)), 10, 64)
		out, truncated, e := s.gitRead(id, 512<<10, nil, "cat-file", "blob", object)
		if e != nil {
			fail(404, "File not found")
		}
		binary := bytes.IndexByte(out, 0) >= 0 || !utf8.Valid(out)
		content := ""
		if !binary {
			content = string(out)
		}
		respond(w, 200, M{"path": p, "content": content, "binary": binary, "truncated": truncated, "size": size})
	case "diff":
		base, e := s.resolve(repo, q.Get("base"))
		if e != nil {
			fail(400, "Base ref not found")
		}
		head, e := s.resolve(repo, q.Get("head"))
		if e != nil {
			fail(400, "Head ref not found")
		}
		out, truncated, e := s.gitRead(id, 1<<20, nil, "diff", "--no-ext-diff", "--no-textconv", "--no-color", base, head, "--")
		if e != nil {
			fail(503, "Cannot generate diff")
		}
		respond(w, 200, M{"diff": string(out), "base_oid": base, "head_oid": head, "truncated": truncated})
	default:
		return false
	}
	return true
}

func (s *server) gitHook(w http.ResponseWriter, r *http.Request, u M, repo M, phase string) {
	repo = s.repo(r, num(repo, "id"), u, "write")
	if phase != "pre-receive" && phase != "post-receive" {
		fail(404, "Git hook not found")
	}
	data := body(r)
	updates, ok := data["updates"].([]any)
	if !ok || len(updates) == 0 || len(updates) > 10000 {
		fail(400, "Updates are required")
	}
	if phase == "post-receive" {
		s.refresh(repo)
		respond(w, 200, M{"ok": true})
		return
	}
	extra := []string{}
	quarantine := str(data, "quarantine_path")
	if quarantine != "" {
		objects := filepath.Join(s.repoPath(num(repo, "id")), "objects")
		clean := filepath.Clean(quarantine)
		if !strings.HasPrefix(filepath.Base(clean), "tmp_objdir-incoming-") {
			fail(400, "Invalid quarantine directory")
		}
		actual, e := filepath.EvalSymlinks(clean)
		realObjects, oe := filepath.EvalSymlinks(objects)
		info, ie := os.Lstat(clean)
		if e != nil || oe != nil || ie != nil || info.Mode()&os.ModeSymlink != 0 || filepath.Dir(actual) != realObjects {
			fail(400, "Invalid quarantine directory")
		}
		extra = []string{"GIT_OBJECT_DIRECTORY=" + clean, "GIT_ALTERNATE_OBJECT_DIRECTORIES=" + objects}
	}
	for _, value := range updates {
		up, ok := value.(map[string]any)
		if !ok {
			fail(400, "Invalid ref update")
		}
		old, new, ref := str(up, "old"), str(up, "new"), str(up, "ref")
		if !oidPattern.MatchString(old) || !oidPattern.MatchString(new) || !strings.HasPrefix(ref, "refs/") {
			fail(400, "Invalid ref update")
		}
		if strings.HasPrefix(ref, "refs/gitclub/") {
			fail(403, "GitClub internal references cannot be pushed")
		}
		if ref != "refs/heads/"+str(repo, "default_branch") || strings.Trim(old, "0") == "" {
			continue
		}
		if strings.Trim(new, "0") == "" {
			fail(403, "Default branch cannot be deleted")
		}
		if boolean(repo, "require_review") {
			fail(403, "Default branch requires a reviewed pull request")
		}
		_, _, err := s.gitReadWaiting(num(repo, "id"), 1024, extra, "", true, "merge-base", "--is-ancestor", old, new)
		if err != nil {
			fail(403, "Default branch only accepts fast-forward updates")
		}
	}
	respond(w, 200, M{"ok": true})
}

func (s *server) gitHTTP(w http.ResponseWriter, r *http.Request, u M) bool {
	p := strings.Split(strings.TrimPrefix(r.URL.Path, "/"), "/")
	if len(p) < 3 || !strings.HasSuffix(p[1], ".git") {
		return false
	}
	tail := strings.Join(p[2:], "/")
	service := r.URL.Query().Get("service")
	if !(r.Method == "GET" && tail == "info/refs" && (service == "git-upload-pack" || service == "git-receive-pack") || r.Method == "POST" && (tail == "git-upload-pack" || tail == "git-receive-pack")) {
		fail(404, "Git endpoint not found")
	}
	receive := tail == "git-receive-pack" || service == "git-receive-pack"
	found := s.one("SELECT id FROM repositories WHERE owner=? AND name=?", p[0], strings.TrimSuffix(p[1], ".git"))
	if found == nil {
		fail(404, "Repository not found")
	}
	minRole := "read"
	if receive {
		minRole = "write"
	}
	if u == nil {
		candidate := s.one("SELECT visibility FROM repositories WHERE id=?", num(found, "id"))
		if receive || str(candidate, "visibility") != "public" {
			w.Header().Set("WWW-Authenticate", `Basic realm="GitClub"`)
			fail(401, "Git credentials required; use your token as the password")
		}
	}
	repo := s.repo(r, num(found, "id"), u, minRole)
	// Reserve two process slots so transfer hooks can finish under transfer load.
	select {
	case s.transferSlots <- struct{}{}:
		defer func() { <-s.transferSlots }()
	default:
		fail(503, "Git transfer capacity exhausted; retry shortly")
	}
	select {
	case s.gitSlots <- struct{}{}:
		defer func() { <-s.gitSlots }()
	default:
		fail(503, "Git transfer capacity exhausted; retry shortly")
	}
	if r.ContentLength > 256<<20 {
		fail(413, "Git request exceeds 256 MiB")
	}
	r.Body = http.MaxBytesReader(w, r.Body, 256<<20)
	ctx, cancel := context.WithTimeout(r.Context(), 120*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", "http-backend")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = time.Second
	_, token := s.authenticate(r)
	cmd.Env = append(safeGitEnv(), "GIT_PROJECT_ROOT="+filepath.Join(s.dataDir, "repos"), "PATH_INFO=/"+strconv.FormatInt(num(repo, "id"), 10)+".git/"+tail, "GIT_HTTP_EXPORT_ALL=1", "REQUEST_METHOD="+r.Method, "QUERY_STRING="+r.URL.RawQuery, "CONTENT_TYPE="+r.Header.Get("Content-Type"), "REMOTE_USER="+str(u, "username"), "GIT_PROTOCOL="+r.Header.Get("Git-Protocol"), "GITCLUB_URL="+s.internalURL, "GITCLUB_TOKEN="+token, "GITCLUB_REPO_ID="+strconv.FormatInt(num(repo, "id"), 10))
	if r.ContentLength >= 0 {
		cmd.Env = append(cmd.Env, "CONTENT_LENGTH="+strconv.FormatInt(r.ContentLength, 10))
	}
	cmd.Stdin = r.Body
	cmd.Stderr = io.Discard
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		fail(503, "Cannot start Git transfer")
	}
	if err = cmd.Start(); err != nil {
		fail(503, "Cannot start Git transfer")
	}
	reader := bufio.NewReaderSize(stdout, 32768)
	status := 200
	total := 0
	for {
		line, err := reader.ReadString('\n')
		total += len(line)
		if err != nil || total > 32768 {
			cancel()
			_ = cmd.Wait()
			fail(502, "Invalid Git response")
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			break
		}
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			cancel()
			_ = cmd.Wait()
			fail(502, "Invalid Git response")
		}
		value = strings.TrimSpace(value)
		if strings.EqualFold(key, "Status") {
			fields := strings.Fields(value)
			if len(fields) > 0 {
				status, _ = strconv.Atoi(fields[0])
			}
		} else {
			w.Header().Add(key, value)
		}
	}
	if status < 100 || status > 599 {
		status = 502
	}
	w.WriteHeader(status)
	if _, err = io.Copy(w, reader); err != nil {
		cancel()
	}
	_ = cmd.Wait()
	return true
}

func (s *server) sshRoutes(w http.ResponseWriter, r *http.Request, u M) bool {
	if strings.HasPrefix(r.URL.Path, "/api/ssh/") {
		secret := s.sshSecret
		provided := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if provided == "" {
			provided = r.Header.Get("X-GitClub-SSH-Secret")
		}
		if secret == "" || subtle.ConstantTimeCompare([]byte(secret), []byte(provided)) != 1 {
			fail(404, "SSH endpoint not found")
		}
		if r.URL.Path == "/api/ssh/authorized-keys" && r.Method == "GET" {
			respond(w, 200, M{"keys": s.rows("SELECT id,public_key FROM ssh_keys ORDER BY id")})
			return true
		}
		if r.URL.Path == "/api/ssh/authorize" && r.Method == "POST" {
			d := body(r)
			key := s.one("SELECT k.user_id,u.username FROM ssh_keys k JOIN users u ON u.id=k.user_id WHERE k.id=?", num(d, "key_id"))
			if key == nil {
				fail(403, "SSH key is not authorized")
			}
			parts := sshCommandPattern.FindStringSubmatch(str(d, "command"))
			if parts == nil {
				fail(400, "Only Git upload-pack and receive-pack commands are allowed")
			}
			identity := M{"id": key["user_id"], "username": key["username"]}
			found := s.one("SELECT id FROM repositories WHERE owner=? AND name=?", parts[2], parts[3])
			if found == nil {
				fail(404, "Repository not found")
			}
			role := "read"
			if parts[1] == "git-receive-pack" {
				role = "write"
			}
			repo := s.repo(r, num(found, "id"), identity, role)
			token := s.newToken(num(identity, "id"))
			hash := sha256.Sum256([]byte(token))
			s.exec("UPDATE tokens SET expires_at=? WHERE token_hash=?", now()+180000, hex.EncodeToString(hash[:]))
			respond(w, 200, M{"repo_id": repo["id"], "user_id": identity["id"], "token": token, "repository_path": s.repoPath(num(repo, "id")), "operation": parts[1], "internal_url": s.internalURL})
			return true
		}
		fail(404, "SSH endpoint not found")
	}
	if r.URL.Path != "/api/ssh-keys" && !strings.HasPrefix(r.URL.Path, "/api/ssh-keys/") {
		return false
	}
	if u == nil {
		fail(401, "Sign in to manage SSH keys")
	}
	if r.URL.Path == "/api/ssh-keys" {
		if r.Method == "GET" {
			respond(w, 200, M{"ssh_keys": s.rows("SELECT id,title,public_key,created_at FROM ssh_keys WHERE user_id=? ORDER BY id", num(u, "id"))})
			return true
		}
		if r.Method == "POST" {
			d := body(r)
			title, key := strings.TrimSpace(str(d, "title")), strings.TrimSpace(str(d, "public_key"))
			if title == "" || len(title) > 120 || len(key) > 16384 || strings.ContainsAny(key, "\r\n") {
				fail(400, "Provide a title and one OpenSSH public key")
			}
			fields := strings.Fields(key)
			if len(fields) < 2 || !(fields[0] == "ssh-ed25519" || fields[0] == "ssh-rsa" || strings.HasPrefix(fields[0], "ecdsa-sha2-nistp")) {
				fail(400, "Unsupported SSH public key")
			}
			canonical := fields[0] + " " + fields[1]
			file, e := os.CreateTemp("", "gitclub-key-*")
			if e != nil {
				fail(503, "Cannot validate SSH key")
			}
			defer os.Remove(file.Name())
			_, e = file.WriteString(canonical + "\n")
			_ = file.Close()
			if e != nil {
				fail(503, "Cannot validate SSH key")
			}
			ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, "ssh-keygen", "-l", "-f", file.Name())
			cmd.Env = safeGitEnv()
			if cmd.Run() != nil {
				fail(400, "Invalid OpenSSH public key")
			}
			if s.one("SELECT id FROM ssh_keys WHERE public_key=? OR public_key LIKE ?", canonical, canonical+" %") != nil {
				fail(409, "SSH key is already registered")
			}
			stamp := now()
			id := s.exec("INSERT INTO ssh_keys(user_id,title,public_key,created_at) VALUES(?,?,?,?)", num(u, "id"), title, key, stamp)
			respond(w, 201, M{"ssh_key": M{"id": id, "title": title, "public_key": key, "created_at": stamp}})
			return true
		}
	} else if r.Method == "DELETE" {
		id, e := strconv.ParseInt(strings.TrimPrefix(r.URL.Path, "/api/ssh-keys/"), 10, 64)
		if e != nil {
			fail(400, "Invalid SSH key ID")
		}
		if s.one("SELECT id FROM ssh_keys WHERE id=? AND user_id=?", id, num(u, "id")) == nil {
			fail(404, "SSH key not found")
		}
		s.exec("DELETE FROM ssh_keys WHERE id=? AND user_id=?", id, num(u, "id"))
		respond(w, 200, M{"ok": true})
		return true
	}
	fail(405, fmt.Sprintf("Method %s is not supported", r.Method))
	return true
}
