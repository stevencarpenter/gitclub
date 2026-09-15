package main

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// testServer builds a server backed by a disposable PostgreSQL schema inside
// the database named by GITCLUB_TEST_DATABASE_URL. Tests that need no database
// must not call it. Without the variable the calling test is skipped, so
// `go test ./...` stays green on a machine with no PostgreSQL.
func testServer(t *testing.T, dataDir string) *server {
	t.Helper()
	url := os.Getenv("GITCLUB_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("set GITCLUB_TEST_DATABASE_URL to run database-backed tests")
	}
	admin, e := sql.Open("pgx", url)
	if e != nil {
		t.Fatal(e)
	}
	if e = admin.Ping(); e != nil {
		admin.Close()
		t.Fatalf("test database unreachable: %v", e)
	}
	schema := fmt.Sprintf("gitclub_test_%d_%d", os.Getpid(), time.Now().UnixNano())
	if _, e = admin.Exec("CREATE SCHEMA " + schema); e != nil {
		admin.Close()
		t.Fatal(e)
	}
	separator := "?"
	if strings.Contains(url, "?") {
		separator = "&"
	}
	db, e := sql.Open("pgx", url+separator+"search_path="+schema)
	if e != nil {
		admin.Close()
		t.Fatal(e)
	}
	sharedDir, e := filepath.Abs("../../shared")
	if e != nil {
		t.Fatal(e)
	}
	s := &server{db: db, dataDir: dataDir, sharedDir: sharedDir,
		gitSlots: make(chan struct{}, 8), transferSlots: make(chan struct{}, 6), rates: map[string]rateEntry{}}
	if e = s.migrate(); e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() {
		db.Close()
		if _, e := admin.Exec("DROP SCHEMA " + schema + " CASCADE"); e != nil {
			t.Logf("dropping test schema %s: %v", schema, e)
		}
		admin.Close()
	})
	return s
}
