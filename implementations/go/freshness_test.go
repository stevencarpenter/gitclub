package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDefaultRefMetadata(t *testing.T) {
	root := t.TempDir()
	s := &server{dataDir: root}
	repo := M{"id": int64(1), "default_branch": "trunk", "default_oid": "old", "updated_at": int64(10)}
	bare := s.repoPath(1)
	write := func(name, content string) {
		t.Helper()
		p := filepath.Join(bare, name)
		if e := os.MkdirAll(filepath.Dir(p), 0700); e != nil {
			t.Fatal(e)
		}
		if e := os.WriteFile(p, []byte(content), 0600); e != nil {
			t.Fatal(e)
		}
	}
	remove := func(name string) {
		t.Helper()
		if e := os.Remove(filepath.Join(bare, name)); e != nil {
			t.Fatal(e)
		}
	}
	a, b := strings.Repeat("a", 40), strings.Repeat("b", 40)
	assertOID := func(want string) {
		t.Helper()
		got, e := s.defaultOID(repo)
		if e != nil || got != want {
			t.Fatalf("got %q (%v), want %q", got, e, want)
		}
	}
	write("refs/heads/trunk", a+"\n")
	assertOID(a)
	write("packed-refs", "# pack-refs with: peeled fully-peeled sorted\n"+b+" refs/heads/trunk\n")
	assertOID(a) // Loose references take precedence over older packed entries.
	remove("refs/heads/trunk")
	assertOID(b)
	write("refs/heads/trunk", "ref: refs/heads/release\n")
	write("refs/heads/release", a+"\n")
	assertOID(a)
	write("refs/heads/release", "ref: refs/heads/trunk\n")
	if _, e := s.defaultOID(repo); e == nil {
		t.Fatal("symbolic reference cycle accepted")
	}
	write("refs/heads/trunk", "ref: ../../outside\n")
	if _, e := s.defaultOID(repo); e == nil {
		t.Fatal("unsafe symbolic target accepted")
	}
}

func TestMissedHookRecovery(t *testing.T) {
	s := testServer(t, t.TempDir())
	repo := M{"id": int64(1), "default_branch": "trunk", "default_oid": "old", "updated_at": int64(10)}
	bare := s.repoPath(1)
	write := func(name, content string) {
		t.Helper()
		p := filepath.Join(bare, name)
		if e := os.MkdirAll(filepath.Dir(p), 0700); e != nil {
			t.Fatal(e)
		}
		if e := os.WriteFile(p, []byte(content), 0600); e != nil {
			t.Fatal(e)
		}
	}
	remove := func(name string) {
		t.Helper()
		if e := os.Remove(filepath.Join(bare, name)); e != nil {
			t.Fatal(e)
		}
	}
	a := strings.Repeat("a", 40)
	s.exec("INSERT INTO namespaces(name,kind) VALUES('owner','user')")
	s.exec("INSERT INTO users(username,password_hash,created_at) VALUES('owner','unused',?)", now())
	s.exec("INSERT INTO repositories(id,owner,name,default_branch,default_oid,created_at,updated_at) VALUES(1,'owner','test','trunk','old',10,10)")
	for _, content := range []string{"invalid\n", strings.Repeat("0", 40), strings.Repeat("a", 1025)} {
		write("refs/heads/trunk", content)
		result := s.refresh(repo)
		if num(result, "updated_at") != 10 || str(result, "default_oid") != "old" {
			t.Fatal("invalid metadata changed freshness")
		}
	}
	write("refs/heads/trunk", a+"\n")
	result := s.refresh(repo)
	if num(result, "updated_at") <= 10 || str(result, "default_oid") != a {
		t.Fatal("missed notification did not reconcile")
	}
	stamp := num(result, "updated_at")
	if num(s.refresh(result), "updated_at") != stamp {
		t.Fatal("unchanged default advanced freshness")
	}
	remove("refs/heads/trunk")
	if num(s.refresh(result), "updated_at") != stamp {
		t.Fatal("missing reference changed freshness")
	}
	write("packed-refs", "malformed metadata\n")
	if num(s.refresh(result), "updated_at") != stamp {
		t.Fatal("invalid packed metadata changed freshness")
	}
}
