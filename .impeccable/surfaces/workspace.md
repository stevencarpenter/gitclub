# GitClub workspace

Mode: Operate.

The user finds a repository across ownership namespaces, inspects code, and completes a review without losing navigation context. Pins and default-branch freshness are the core discovery signals. Groups are optional collections with explicit sharing and independent repository permissions.

The implementation uses the visual direction in DESIGN.md. The shared browser assets serve both independent backends so the implementation comparison keeps the interaction surface constant. The current brief includes authentication, repository creation and Git-history import, code browsing, issues, pull requests, review, permissions, organization creation, SSH keys, and external agent configuration. CI and hosted agent execution are excluded.

Acceptance requires working forms, live API data, accessible empty/error/loading states, desktop and mobile navigation, and keyboard repository switching. Browser inspection is performed by the root implementation agent against the running servers.
