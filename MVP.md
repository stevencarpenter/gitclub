# GitClub MVP

GitClub is an original, self-hosted Git collaboration server. Its priorities are reliable Git operations, responsive navigation, and an efficient developer workflow. The application must not be derived from Gitea or another existing forge. Standard Git and general-purpose dependencies are compatible with that constraint.

## Confirmed requirements

### Repository navigation

- Find accessible repositories from personal and organization namespaces in one repositories screen or sidebar. Switching owners must not be necessary to find a repository.
- Support repository pins.
- Order repositories by the freshness of their configured default branch, without assuming its name is `main`.
- Try custom groups containing repositories from multiple owners. Groups can be shared; they are not restricted to private collections.

### Agent access

- Provide a native surface for existing Codex and Claude agents to work with GitClub.
- Agents run in the user's existing tools. GitClub does not launch, host, or manage agent execution in the MVP.

### Task tracking

- Use Kaneo for tasks instead of a built-in issue tracker.
- Link repositories and pull requests to Kaneo projects and tasks.
- Complete linked tasks when pull requests merge, with repository/project authorization enforced by the sync configuration.

### Deployment and migration

- Target self-hosted installation first.
- Import Git history. Migration of issues, reviews, comments, accounts, and other provider metadata is excluded.
- CI is excluded from the MVP, including runners, pipeline configuration, and build-status integrations.
- Keep the implementation lean. Uptime and performance take priority over feature breadth.

## Implemented defaults

These implementation choices make the scoped MVP concrete.

- Keep pins at the top. Sort both pinned and unpinned repositories by default-branch freshness, including inside groups. Show `owner/repository` where names could collide.
- Measure freshness using the server's accepted default-branch update time. Feature-branch pushes, comments, and page visits do not affect the order. Import initialization and changing the default branch need deterministic behavior that does not invent historical server activity.
- Sharing a group grants no repository permissions. Filter its contents using the viewer's access, including repository names and counts.
- Provide Git over SSH and HTTPS, repository browsing, diffs, Kaneo task links, pull requests, reviews, and protected merges. Use the standard Git implementation for Git operations.
- Expose application operations through an API and MCP surface shared by Codex and Claude. Apply repository permissions and branch protections to every access path. Git transfers remain standard Git operations.

## Acceptance criteria

1. Import a real repository with its Git history, branches, and tags intact. Clone it and push a branch using a standard Git client.
2. Find personal and organization repositories together. Verify pins, shared groups, access filtering, and ordering after default-branch and feature-branch updates.
3. Open a pull request, review it using another account, and merge it with configured permissions and branch protections enforced. No CI service is required.
4. Expose repository discovery, code and diff reads, pull-request writes with Kaneo task links, and review feedback through the MCP integration for Codex and Claude. Verify the protocol with the official SDK and verify configuration flags against the installed clients.
5. Verify restart persistence and restoration on a fresh installation. Measure navigation and Git-operation latency against recorded repository sizes, hardware, and concurrency. Test that failures in optional background work do not interrupt authorized Git operations.

The implementation is Go, with Docker packaging and repeatable validation. Go was chosen over parallel Gleam and Rust implementations of this same contract; DECISION.md records the evidence and the reasoning, and tag `v0.0.0` holds all three. Reliability and performance claims remain limited to the evidence recorded there.
