package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	_ "github.com/jackc/pgx/v5/stdlib"
)

// rebind converts the portable "?" placeholders used throughout the queries
// into PostgreSQL's positional form. Single-quoted literals are skipped so a
// "?" inside a string constant is never renumbered.
func rebind(query string) string {
	var out strings.Builder
	out.Grow(len(query) + 8)
	n, quoted := 0, false
	for i := 0; i < len(query); i++ {
		c := query[i]
		switch {
		case c == '\'':
			quoted = !quoted
			out.WriteByte(c)
		case c == '?' && !quoted:
			n++
			out.WriteByte('$')
			out.WriteString(strconv.Itoa(n))
		default:
			out.WriteByte(c)
		}
	}
	return out.String()
}

func uniqueViolation(e error) bool {
	var pge *pgconn.PgError
	return errors.As(e, &pge) && pge.Code == "23505"
}

func openDatabase() *sql.DB {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		log.Fatal("DATABASE_URL is required (postgres://user:password@host:port/database)")
	}
	db, e := sql.Open("pgx", url)
	if e != nil {
		log.Fatal(e)
	}
	// Repository locks hold a session for the duration of a Git operation, so
	// the pool must exceed the 8 concurrent Git slots plus ordinary traffic.
	db.SetMaxOpenConns(25)
	db.SetMaxIdleConns(8)
	db.SetConnMaxLifetime(time.Hour)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for {
		if e = db.PingContext(ctx); e == nil {
			return db
		}
		select {
		case <-ctx.Done():
			log.Fatalf("database unreachable: %v", e)
		case <-time.After(500 * time.Millisecond):
		}
	}
}

// migrate applies every unapplied file in SHARED_DIR/migrations in name order,
// each in its own transaction, and records it. Listening waits on this.
func (s *server) migrate() error {
	if _, e := s.db.Exec("CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, applied_at BIGINT NOT NULL)"); e != nil {
		return e
	}
	applied := map[string]bool{}
	rs, e := s.db.Query("SELECT version FROM schema_migrations")
	if e != nil {
		return e
	}
	for rs.Next() {
		var v string
		if e = rs.Scan(&v); e != nil {
			rs.Close()
			return e
		}
		applied[v] = true
	}
	rs.Close()
	if e = rs.Err(); e != nil {
		return e
	}
	files, e := filepath.Glob(filepath.Join(s.sharedDir, "migrations", "*.sql"))
	if e != nil {
		return e
	}
	sort.Strings(files)
	for _, file := range files {
		version := strings.TrimSuffix(filepath.Base(file), ".sql")
		if applied[version] {
			continue
		}
		body, e := os.ReadFile(file)
		if e != nil {
			return e
		}
		tx, e := s.db.Begin()
		if e != nil {
			return e
		}
		if _, e = tx.Exec(string(body)); e != nil {
			tx.Rollback()
			return fmt.Errorf("migration %s: %w", version, e)
		}
		if _, e = tx.Exec("INSERT INTO schema_migrations(version,applied_at) VALUES($1,$2)", version, now()); e != nil {
			tx.Rollback()
			return fmt.Errorf("migration %s: %w", version, e)
		}
		if e = tx.Commit(); e != nil {
			return fmt.Errorf("migration %s: %w", version, e)
		}
		log.Printf("applied migration %s", version)
	}
	return nil
}

func (s *server) rows(query string, args ...any) []M {
	rs, e := s.db.Query(rebind(query), args...)
	if e != nil {
		log.Printf("database query: %v", e)
		fail(500, "Database operation failed")
	}
	defer rs.Close()
	cols, _ := rs.Columns()
	out := []M{}
	for rs.Next() {
		vals := make([]any, len(cols))
		ptr := make([]any, len(cols))
		for i := range vals {
			ptr[i] = &vals[i]
		}
		if rs.Scan(ptr...) != nil {
			fail(500, "Database read failed")
		}
		m := M{}
		for i, c := range cols {
			if b, ok := vals[i].([]byte); ok {
				m[c] = string(b)
			} else {
				m[c] = vals[i]
			}
		}
		out = append(out, m)
	}
	if rs.Err() != nil {
		fail(500, "Database read failed")
	}
	return out
}

func (s *server) one(q string, args ...any) M {
	rows := s.rows(q, args...)
	if len(rows) == 0 {
		return nil
	}
	return rows[0]
}

func (s *server) exec(q string, args ...any) int64 {
	r, e := s.db.Exec(rebind(q), args...)
	if e != nil {
		log.Printf("database write: %v", e)
		if uniqueViolation(e) {
			fail(409, "That name or entry already exists")
		}
		fail(500, "Database operation failed")
	}
	affected, _ := r.RowsAffected()
	return affected
}

// insert runs an INSERT and returns the generated identifier. PostgreSQL has
// no LastInsertId, so the identifier comes back through RETURNING.
func (s *server) insert(q string, args ...any) int64 {
	var id int64
	e := s.db.QueryRow(rebind(q)+" RETURNING id", args...).Scan(&id)
	if e != nil {
		log.Printf("database insert: %v", e)
		if uniqueViolation(e) {
			fail(409, "That name or entry already exists")
		}
		fail(500, "Database operation failed")
	}
	return id
}

// lockRepo serializes mutations for one repository across every server
// instance. A session-scoped advisory lock replaces an in-process mutex, which
// would serialize nothing once a second instance exists. The key space is the
// repository identifier; this database has no other advisory lock user.
func (s *server) lockRepo(r *http.Request, id int64) func() {
	conn, e := s.db.Conn(context.Background())
	if e != nil {
		fail(503, "Database is busy; retry shortly")
	}
	release := func() {
		_, _ = conn.ExecContext(context.Background(), "SELECT pg_advisory_unlock($1)", id)
		conn.Close()
	}
	abandon := func(status int, message string) {
		conn.Close()
		fail(status, message)
	}
	timeout := time.NewTimer(30 * time.Second)
	defer timeout.Stop()
	retry := time.NewTicker(10 * time.Millisecond)
	defer retry.Stop()
	for {
		var held bool
		if e := conn.QueryRowContext(context.Background(), "SELECT pg_try_advisory_lock($1)", id).Scan(&held); e != nil {
			log.Printf("repository lock: %v", e)
			abandon(500, "Database operation failed")
		}
		if held {
			return release
		}
		select {
		case <-r.Context().Done():
			abandon(408, "Request canceled while waiting for repository")
		case <-timeout.C:
			abandon(503, "Repository is busy; retry shortly")
		case <-retry.C:
		}
	}
}
