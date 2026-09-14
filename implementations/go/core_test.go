package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPasswordHash(t *testing.T) {
	h := passwordHash("long-password-123")
	if !passwordMatches("long-password-123", h) || passwordMatches("wrong-password", h) {
		t.Fatal("password verification failed")
	}
	if h == passwordHash("long-password-123") {
		t.Fatal("password salts must be random")
	}
}
func TestRoleAndNameValidation(t *testing.T) {
	for _, s := range []string{"../private", "-flag", "UPPER", "a/b", ""} {
		if nameOK(s) {
			t.Fatalf("accepted unsafe name %q", s)
		}
	}
	if !nameOK("my-repo") || rank("admin") <= rank("write") || rank("write") <= rank("read") {
		t.Fatal("role or name invariant")
	}
}
func TestRejectCrossOriginCookieMutation(t *testing.T) {
	s := &server{publicURL: "https://gitclub.example"}
	r := httptest.NewRequest(http.MethodPost, "/api/repos", strings.NewReader(`{}`))
	r.AddCookie(&http.Cookie{Name: "gc_session", Value: ""})
	r.Header.Set("Origin", "https://attacker.example")
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatalf("status %d body %s", w.Code, w.Body.String())
	}
}
func TestBodyRejectsTrailingJSON(t *testing.T) {
	defer func() {
		e := recover()
		a, ok := e.(apiError)
		if !ok || a.status != 400 {
			t.Fatalf("expected 400 got %v", e)
		}
	}()
	r := httptest.NewRequest("POST", "/", strings.NewReader(`{} {}`))
	body(r)
}
func TestJSONNumber(t *testing.T) {
	if num(M{"id": json.Number("123")}, "id") != 123 {
		t.Fatal("JSON IDs must decode")
	}
}

func TestCappedOutputReadFrom(t *testing.T) {
	out := &cappedOutput{cap: 512 << 10}
	size := int64(760000)
	written, err := io.Copy(out, io.LimitReader(strings.NewReader(strings.Repeat("a", int(size))), size))
	if err != nil || written != size || out.Len() != 512<<10 || !out.truncated {
		t.Fatalf("cap bypassed: written=%d retained=%d truncated=%v error=%v", written, out.Len(), out.truncated, err)
	}
}
func TestRepositoryLockHonorsCancellation(t *testing.T) {
	s := &server{}
	lock := s.repoLock(1)
	lock.Lock()
	defer lock.Unlock()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r := httptest.NewRequest("GET", "/", nil).WithContext(ctx)
	defer func() {
		a, ok := recover().(apiError)
		if !ok || a.status != 408 {
			t.Fatalf("expected canceled waiter, got %+v", a)
		}
	}()
	s.lockRepo(r, 1)
}
