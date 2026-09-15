package main

import (
	"context"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

type M = map[string]any
type apiError struct {
	status  int
	message string
}

func fail(status int, message string) { panic(apiError{status, message}) }
func str(m M, k string) string        { v, _ := m[k].(string); return v }
func num(m M, k string) int64 {
	switch v := m[k].(type) {
	case int64:
		return v
	case int:
		return int64(v)
	case int32:
		return int64(v)
	case float64:
		return int64(v)
	case json.Number:
		n, _ := v.Int64()
		return n
	}
	return 0
}
func boolean(m M, k string) bool {
	switch v := m[k].(type) {
	case bool:
		return v
	case int64:
		return v != 0
	case int32:
		return v != 0
	case float64:
		return v != 0
	}
	return false
}
func now() int64 { return time.Now().UnixMilli() }
func respond(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(value)
}
func body(r *http.Request) M {
	d := json.NewDecoder(io.LimitReader(r.Body, 1048577))
	d.UseNumber()
	var m M
	if d.Decode(&m) != nil || m == nil {
		fail(400, "Provide a JSON object (maximum 1 MiB)")
	}
	if d.Decode(new(any)) != io.EOF {
		fail(400, "Provide one JSON object")
	}
	return m
}
func rank(role string) int {
	switch role {
	case "admin":
		return 3
	case "write":
		return 2
	case "read":
		return 1
	}
	return 0
}

var validName = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,62}$`)

func nameOK(v string) bool { return validName.MatchString(v) && v != "." && v != ".." }
func requireUser(u M) {
	if u == nil {
		fail(401, "Sign in to continue")
	}
}

type rateEntry struct {
	count int
	since time.Time
}
type server struct {
	db                                                            *sql.DB
	dataDir, sharedDir, webDir, publicURL, internalURL, sshSecret string
	backupUserID                                                  int64
	gitSlots, transferSlots                                       chan struct{}
	rates                                                         map[string]rateEntry
	rateMu                                                        sync.Mutex
}

func tokenHash(t string) string { h := sha256.Sum256([]byte(t)); return hex.EncodeToString(h[:]) }
func (s *server) newToken(uid int64) string {
	b := make([]byte, 32)
	if _, e := rand.Read(b); e != nil {
		fail(500, "Token generation failed")
	}
	t := hex.EncodeToString(b)
	s.exec("INSERT INTO tokens(token_hash,user_id,created_at) VALUES(?,?,?)", tokenHash(t), uid, now())
	return t
}
func passwordHash(p string) string {
	salt := make([]byte, 16)
	if _, e := rand.Read(salt); e != nil {
		fail(500, "Password generation failed")
	}
	h, e := pbkdf2.Key(sha256.New, p, salt, 600000, 32)
	if e != nil {
		fail(500, "Password generation failed")
	}
	return "pbkdf2_sha256$600000$" + hex.EncodeToString(salt) + "$" + hex.EncodeToString(h)
}
func passwordMatches(p, h string) bool {
	a := strings.Split(h, "$")
	if len(a) != 4 || a[0] != "pbkdf2_sha256" || a[1] != "600000" {
		return false
	}
	salt, e := hex.DecodeString(a[2])
	if e != nil {
		return false
	}
	expected, e := hex.DecodeString(a[3])
	if e != nil {
		return false
	}
	got, e := pbkdf2.Key(sha256.New, p, salt, 600000, 32)
	return e == nil && subtle.ConstantTimeCompare(expected, got) == 1
}
func (s *server) authenticate(r *http.Request) (M, string) {
	t := ""
	if strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
		t = strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	} else if strings.Contains(r.URL.Path, ".git/") {
		_, t, _ = r.BasicAuth()
	}
	if t == "" {
		if c, e := r.Cookie("gc_session"); e == nil {
			t = c.Value
		}
	}
	if t == "" {
		return nil, ""
	}
	u := s.one("SELECT users.id,users.username FROM users JOIN tokens ON users.id=tokens.user_id WHERE token_hash=? AND (expires_at=0 OR expires_at>?)", tokenHash(t), now())
	return u, t
}
func (s *server) cookie(w http.ResponseWriter, t string) {
	age := 60 * 60 * 24 * 30
	if t == "" {
		age = -1
	}
	http.SetCookie(w, &http.Cookie{Name: "gc_session", Value: t, Path: "/", HttpOnly: true, Secure: strings.HasPrefix(s.publicURL, "https://"), SameSite: http.SameSiteStrictMode, MaxAge: age})
}
func (s *server) rate(r *http.Request) {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	s.rateMu.Lock()
	defer s.rateMu.Unlock()
	t := time.Now()
	v := s.rates[host]
	if t.Sub(v.since) > time.Minute {
		v = rateEntry{since: t}
	}
	if len(s.rates) >= 4096 {
		for k, x := range s.rates {
			if t.Sub(x.since) > time.Minute {
				delete(s.rates, k)
			}
		}
		if len(s.rates) >= 4096 {
			fail(429, "Authentication busy; retry in one minute")
		}
	}
	s.rates[host] = v
	if v.count >= 20 {
		fail(429, "Too many authentication attempts; retry in one minute")
	}
}
func (s *server) authAttempt(r *http.Request) func() {
	s.rate(r)
	return func() {
		if e := recover(); e != nil {
			if a, ok := e.(apiError); ok && a.status >= 400 && a.status < 500 {
				host, _, _ := net.SplitHostPort(r.RemoteAddr)
				s.rateMu.Lock()
				v := s.rates[host]
				v.count++
				s.rates[host] = v
				s.rateMu.Unlock()
			}
			panic(e)
		}
	}
}
func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	defer func() {
		if e := recover(); e != nil {
			if a, ok := e.(apiError); ok {
				respond(w, a.status, M{"error": a.message})
			} else {
				log.Printf("request panic: %v", e)
				respond(w, 500, M{"error": "Internal operation failed"})
			}
		}
	}()
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "same-origin")
	w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
	if r.URL.Path == "/health" {
		respond(w, 200, M{"status": "ok", "implementation": "go"})
		return
	}
	u, _ := s.authenticate(r)
	if r.Method != "GET" && r.Method != "HEAD" {
		if origin := r.Header.Get("Origin"); origin != "" && strings.TrimRight(origin, "/") != strings.TrimRight(s.publicURL, "/") {
			fail(403, "Use a same-origin request")
		}
	}
	if r.Method != "GET" && r.Method != "HEAD" && r.Header.Get("Authorization") == "" {
		if _, e := r.Cookie("gc_session"); e == nil {
			origin := r.Header.Get("Origin")
			if (origin != "" && strings.TrimRight(origin, "/") != strings.TrimRight(s.publicURL, "/")) || (origin == "" && r.Header.Get("X-GitClub-Request") != "1") || !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
				fail(403, "Use a same-origin JSON request")
			}
		}
	}
	if s.gitHTTP(w, r, u) {
		return
	}
	if r.URL.Path == "/mcp" {
		s.mcp(w, r, u)
		return
	}
	if strings.HasPrefix(r.URL.Path, "/api/") {
		controller := http.NewResponseController(w)
		_ = controller.SetReadDeadline(time.Now().Add(10 * time.Second))
		defer controller.SetReadDeadline(time.Time{})
		r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
		s.api(w, r, u)
		return
	}
	if r.Method != "GET" && r.Method != "HEAD" {
		fail(405, "Use GET")
	}
	p := filepath.Join(s.webDir, filepath.Clean("/"+r.URL.Path))
	if info, e := os.Stat(p); e == nil && !info.IsDir() {
		http.ServeFile(w, r, p)
	} else {
		http.ServeFile(w, r, filepath.Join(s.webDir, "index.html"))
	}
}
func (s *server) api(w http.ResponseWriter, r *http.Request, u M) {
	p := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	path := r.URL.Path
	if path == "/api/auth/register" && r.Method == "POST" {
		defer s.authAttempt(r)()
		b := body(r)
		username, password := str(b, "username"), str(b, "password")
		if !nameOK(username) || len(password) < 12 || len(password) > 256 {
			fail(400, "Use a lowercase username and a password of 12 to 256 bytes")
		}
		hash := passwordHash(password)
		tx, e := s.db.Begin()
		if e != nil {
			fail(500, "Database operation failed")
		}
		defer tx.Rollback()
		var id int64
		if e = tx.QueryRow("INSERT INTO users(username,password_hash,created_at) VALUES($1,$2,$3) RETURNING id", username, hash, now()).Scan(&id); e != nil {
			fail(409, "Username already exists")
		}
		if _, e = tx.Exec("INSERT INTO namespaces(name,kind) VALUES($1,'user')", username); e != nil {
			fail(409, "Namespace already exists")
		}
		if _, e = tx.Exec("INSERT INTO namespace_members(namespace,user_id,role) VALUES($1,$2,'admin')", username, id); e != nil {
			fail(500, "Registration failed")
		}
		if tx.Commit() != nil {
			fail(500, "Registration failed")
		}
		t := s.newToken(id)
		s.cookie(w, t)
		respond(w, 201, M{"user": M{"id": id, "username": username}, "token": t})
		return
	}
	if path == "/api/auth/login" && r.Method == "POST" {
		defer s.authAttempt(r)()
		b := body(r)
		user := s.one("SELECT * FROM users WHERE username=?", str(b, "username"))
		hash := str(user, "password_hash")
		if hash == "" {
			hash = "pbkdf2_sha256$600000$00000000000000000000000000000000$0000000000000000000000000000000000000000000000000000000000000000"
		}
		if len(str(b, "password")) > 256 || !passwordMatches(str(b, "password"), hash) || user == nil {
			fail(401, "Incorrect username or password")
		}
		t := s.newToken(num(user, "id"))
		s.cookie(w, t)
		respond(w, 200, M{"user": M{"id": user["id"], "username": user["username"]}, "token": t})
		return
	}
	if path == "/api/auth/logout" && r.Method == "POST" {
		_, t := s.authenticate(r)
		s.exec("DELETE FROM tokens WHERE token_hash=?", tokenHash(t))
		s.cookie(w, "")
		respond(w, 200, M{"ok": true})
		return
	}
	if path == "/api/session" && r.Method == "GET" {
		respond(w, 200, M{"user": u})
		return
	}
	if s.sshRoutes(w, r, u) {
		return
	}
	if path == "/api/users" && r.Method == "GET" {
		requireUser(u)
		q := "%" + r.URL.Query().Get("q") + "%"
		respond(w, 200, M{"users": s.rows("SELECT id,username FROM users WHERE username LIKE ? ORDER BY username LIMIT 100", q)})
		return
	}
	if len(p) >= 2 && p[1] == "namespaces" {
		s.namespaces(w, r, u, p[2:])
		return
	}
	if len(p) >= 2 && p[1] == "groups" {
		s.groups(w, r, u, p[2:])
		return
	}
	if len(p) >= 2 && p[1] == "repos" {
		s.repositories(w, r, u, p[2:])
		return
	}
	fail(404, "Endpoint not found")
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
func main() {
	port := env("PORT", "7701")
	s := &server{gitSlots: make(chan struct{}, 8), transferSlots: make(chan struct{}, 6), rates: map[string]rateEntry{}, sshSecret: os.Getenv("GITCLUB_SSH_SECRET")}
	s.dataDir, _ = filepath.Abs(env("DATA_DIR", ".data/go"))
	s.sharedDir, _ = filepath.Abs(env("SHARED_DIR", "shared"))
	s.webDir, _ = filepath.Abs(env("WEB_DIR", "web"))
	s.publicURL = env("PUBLIC_URL", "http://localhost:"+port)
	s.internalURL = "http://127.0.0.1:" + port
	if e := os.MkdirAll(filepath.Join(s.dataDir, "repos"), 0700); e != nil {
		log.Fatal(e)
	}
	s.db = openDatabase()
	defer s.db.Close()
	if e := s.migrate(); e != nil {
		log.Fatal(e)
	}
	if e := s.configureBackupUser(os.Getenv("GITCLUB_BACKUP_USERNAME")); e != nil {
		log.Fatal(e)
	}
	srv := &http.Server{Addr: net.JoinHostPort(env("HOST", "127.0.0.1"), port), Handler: s, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 130 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 1 << 16}
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-ch
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if srv.Shutdown(ctx) != nil {
			srv.Close()
		}
	}()
	log.Printf("GitClub Go listening on %s", srv.Addr)
	if e := srv.ListenAndServe(); e != nil && !errors.Is(e, http.ErrServerClosed) {
		log.Fatal(e)
	}
}

// MCP dispatches only declared mappings through the same authenticated API router.
func (s *server) mcp(w http.ResponseWriter, r *http.Request, u M) {
	if r.Method != "POST" {
		fail(405, "Use POST for stateless MCP")
	}
	requireUser(u)
	if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
		fail(401, "MCP requires a Bearer token")
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	var req M
	if json.NewDecoder(r.Body).Decode(&req) != nil {
		respond(w, 200, M{"jsonrpc": "2.0", "id": nil, "error": M{"code": -32700, "message": "Parse error"}})
		return
	}
	id := req["id"]
	reply := func(result any) { respond(w, 200, M{"jsonrpc": "2.0", "id": id, "result": result}) }
	rpcError := func(code int, msg string) {
		respond(w, 200, M{"jsonrpc": "2.0", "id": id, "error": M{"code": code, "message": msg}})
	}
	method := str(req, "method")
	params, _ := req["params"].(map[string]any)
	switch method {
	case "initialize":
		v := str(params, "protocolVersion")
		if v != "2024-11-05" && v != "2025-03-26" && v != "2025-06-18" {
			v = "2025-06-18"
		}
		reply(M{"protocolVersion": v, "capabilities": M{"tools": M{}}, "serverInfo": M{"name": "gitclub-go", "version": "0.1.0"}})
	case "notifications/initialized":
		w.WriteHeader(202)
	case "ping":
		reply(M{})
	case "tools/list", "tools/call":
		data, e := os.ReadFile(filepath.Join(s.sharedDir, "mcp-tools.json"))
		if e != nil {
			rpcError(-32603, "Tool declarations unavailable")
			return
		}
		var tools []M
		if json.Unmarshal(data, &tools) != nil {
			rpcError(-32603, "Invalid tool declarations")
			return
		}
		if method == "tools/list" {
			out := []M{}
			for _, t := range tools {
				delete(t, "http")
				out = append(out, t)
			}
			reply(M{"tools": out})
			return
		}
		name := str(params, "name")
		var tool M
		for _, t := range tools {
			if str(t, "name") == name {
				tool = t
				break
			}
		}
		if tool == nil {
			rpcError(-32602, "Unknown tool")
			return
		}
		args, _ := params["arguments"].(map[string]any)
		mapping, _ := tool["http"].(map[string]any)
		path := str(mapping, "path")
		for key, value := range args {
			path = strings.ReplaceAll(path, "{"+key+"}", url.PathEscape(fmt.Sprint(value)))
		}
		if strings.ContainsAny(path, "{}") || !strings.HasPrefix(path, "/api/") {
			rpcError(-32602, "Missing route arguments")
			return
		}
		query := url.Values{}
		if keys, ok := mapping["query"].([]any); ok {
			for _, key := range keys {
				if v, exists := args[fmt.Sprint(key)]; exists {
					query.Set(fmt.Sprint(key), fmt.Sprint(v))
				}
			}
		}
		if len(query) > 0 {
			path += "?" + query.Encode()
		}
		payload := args
		if keys, ok := mapping["body"].([]any); ok {
			payload = M{}
			for _, key := range keys {
				if v, exists := args[fmt.Sprint(key)]; exists {
					payload[fmt.Sprint(key)] = v
				}
			}
		}
		encoded, _ := json.Marshal(payload)
		child := httptest.NewRequest(str(mapping, "method"), path, strings.NewReader(string(encoded)))
		child.Header.Set("Authorization", r.Header.Get("Authorization"))
		child.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()
		s.ServeHTTP(rec, child)
		reply(M{"content": []M{{"type": "text", "text": rec.Body.String()}}, "isError": rec.Code >= 400})
	default:
		rpcError(-32601, "Method not found")
	}
}
