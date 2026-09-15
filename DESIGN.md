# GitClub interface

<!-- impeccable:design-schema 1 -->

GitClub uses a restrained workspace with dark mode as the default, optimized for sustained reading, repository discovery, and code review. The interface was built directly from the agreed navigation requirements, as requested, with a restrained visual direction for sustained developer work.

The default content surface is a dark green neutral, with a darker navigation surface and raised panels. Soft green identifies the wordmark, primary actions, and selection. Light mode retains the warm white content surface, neutral navigation, and dark green accents. Muted text remains readable in both modes. Red identifies destructive decisions and errors. The header theme control saves the browser’s explicit choice; new visits default to dark regardless of the operating system setting. The saved choice is applied before the stylesheet paints, and theme switching remains available when browser storage is disabled. Source code and identifiers use the platform monospace family; interface text uses the platform sans family.

Repository discovery occupies a single directory with explicit owner/name labels, optional owner and group filters, pinned repositories first, and default-branch freshness ordering. The sidebar preserves the same cross-owner context throughout repository work. It contains pins, accessible shared and personal groups, and repository links. Shared collections do not grant repository access.

Repository navigation exposes code and pull requests, plus a Kaneo project link when configured. Repository settings connect the project; pull request forms accept a task URL from that project. Task planning stays in Kaneo. Legacy issue bookmarks explain the move and offer the connected project link.

The layout uses compact rows, clear section boundaries, native form controls, and one consistent button vocabulary. Empty states explain the next available action. Source and discussion text are rendered as text. No fabricated repositories, activity, or performance claims appear.

Desktop has a 252px navigation column and a bounded reading area. Below 800px, navigation becomes an explicitly opened overlay, repository metadata wraps, and toolbars stack. Keyboard users have a skip link, visible focus, a repository switcher, native dialog focus management, and descriptive action labels. Reduced motion disables the switcher reveal.

Forms retain user-entered values after errors. Discussion drafts are local, scoped to user and resource; passwords and credentials are never persisted by the interface. Tokens are shown only in the current agent setup session after explicit reauthentication.
