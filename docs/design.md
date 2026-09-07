# Terminal selection design

The numbered-list prototype becomes difficult to navigate when a development Mac has hundreds of similarly named entries. Truncated paths can hide the distinction between an installed application and an old build. Filtering also needs to preserve and disclose selections that are no longer visible.

The fullscreen picker uses three stable regions: status and filter, scrollable table, and wrapped details with keyboard hints. The table shows identity, selection, permission, and executable status. The details pane starts with the user and executable path, which distinguish otherwise similar entries. Tab gives it its own scroll position. Selection and hidden counts have a dedicated line, and preparation versus application is explained within the minimum supported width. Filtering replaces the normal key hints with text-entry controls; Space and q are search characters in that mode. The review screen includes all selections with their full details and requires `p` to prepare; Enter alone does not prepare a change.

| Token | Rendering |
| --- | --- |
| Primary | Terminal's default foreground |
| Secondary | Dim metadata and full-path details |
| Muted hint | Dim keyboard hints and status text |
| Action accent | Local cyan selection/focus markers, bold without color |

No spinner or streaming transcript is needed: this is a local snapshot picker. ncurses redraws from the current state, handles width changes, and restores terminal settings on cancellation and signals. The fullscreen picker and human-readable CLI/Recovery output share one sanitizer for terminal controls, bidirectional overrides, and invisible format characters. Ordinary Unicode text stays intact. JSON output preserves original data. Recovery review includes application names, users, and the full recorded identity and path; path existence is explicitly identified as the status at preparation. Recovery answers accept either letter case, while an empty final confirmation still declines. The interface does not execute or write anything; it returns exact selection tokens to preparation.
