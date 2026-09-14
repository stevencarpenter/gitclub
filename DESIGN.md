# GitClub interface

<!-- impeccable:design-schema 1 -->

GitClub uses a restrained light workspace optimized for sustained reading, repository discovery, and code review. The interface was built directly from the agreed navigation requirements, as requested, with a restrained visual direction for sustained developer work.

The content surface is warm white. The persistent navigation surface is a slightly darker neutral. Dark green identifies the wordmark, primary actions, and selection. Muted text remains readable. Red identifies destructive decisions and errors. Source code and identifiers use the platform monospace family; interface text uses the platform sans family.

Repository discovery occupies a single directory with explicit owner/name labels, optional owner and group filters, pinned repositories first, and default-branch freshness ordering. The sidebar preserves the same cross-owner context throughout repository work. It contains pins, accessible shared and personal groups, and repository links. Shared collections do not grant repository access.

The layout uses compact rows, clear section boundaries, native form controls, and one consistent button vocabulary. Empty states explain the next available action. Source and discussion text are rendered as text. No fabricated repositories, activity, or performance claims appear.

Desktop has a 252px navigation column and a bounded reading area. Below 800px, navigation becomes an explicitly opened overlay, repository metadata wraps, and toolbars stack. Keyboard users have a skip link, visible focus, a repository switcher, native dialog focus management, and descriptive action labels. Reduced motion disables the switcher reveal.

Forms retain user-entered values after errors. Discussion drafts are local, scoped to user and resource; passwords and credentials are never persisted by the interface. Tokens are shown only in the current agent setup session after explicit reauthentication.
