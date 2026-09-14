# GitClub

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

Three independently implemented servers, Go, Gleam on Erlang, and Rust, explicitly requested by the user for comparison. Shared browser interface and acceptance tests hold product behavior constant. Plain HTML, CSS, and browser JavaScript are an implementation default chosen to keep the comparison lean, not a separately confirmed user preference.

## Users

Developers working across repositories owned by their personal account and organizations. The initial user finds switching ownership contexts to discover repositories frustrating.

## Product Purpose

Self-host Git repositories and collaborate on code with responsive navigation and reliable Git operations.

## Operating Context

Existing Git clients and external Codex and Claude tools. The user does not want GitClub to run agents. Repository import preserves Git history only. CI is excluded from the MVP.

## Capabilities and Constraints

Accessible repositories belong in one screen and persistent sidebar across owners. Pins are required. Repository ordering reflects configured default-branch freshness. Custom groups are experimental and can be shared. Repository permissions remain independent of grouping. The implementation is original and does not derive from another forge.

## Brand Commitments

Name: GitClub. The user wants a focused developer experience with no unnecessary features, emphasizing uptime and performance.

## Evidence on Hand

MVP.md records requirements and proposed defaults. shared/CONTRACT.md defines equivalent behavior for the three implementations. COMPARISON.md records local benchmark results. Production uptime has not been measured. The interface must not invent projects, customers, or performance claims.

## Product Principles

- Find code across ownership boundaries without changing workspaces.
- Put current default-branch activity ahead of incidental viewing activity.
- Keep Git operations reliable when optional work fails.
- Support the user's existing agents through native operations.
- Verify equivalent behavior before comparing implementations.

## Accessibility & Inclusion

The user has requested low cognitive load in communication. The application should support keyboard use, visible focus, readable contrast, and responsive layout. These UI provisions are implementation defaults consistent with the task.
