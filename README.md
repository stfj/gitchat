# gitchat

Your GitHub issues, as chats. A native macOS menu bar app that presents every
issue you can see on GitHub as an iMessage-style conversation.

## What it does

- **Menu bar item with an unread count** (Dropbox-style). Left-click toggles the
  chat window; right-click gives a menu (Open, New Issue, Sync Now, Mark All as
  Read, Settings, Quit).
- **Messages-style window** — chat list on the left (pinned chats up top as a
  grid of circles), conversation on the right rendered as chat bubbles: the
  issue body is the first message, comments follow, yours on the right in blue.
- **Reply from the composer** (Return sends, ⌥Return for a newline) — posts a
  real GitHub comment. Failed sends show a retry button. Typing `@` pops up
  username autocomplete (recent speakers in the chat first, then assignees and
  repo collaborators; ↑/↓ to pick, Tab/Return to accept, Esc to dismiss).
- **Markdown renders properly in bubbles** — headings, bullet/numbered lists,
  task lists, blockquotes, code blocks, tables, and rules, plus inline
  bold/italic/code/links. `@mentions` are highlighted and click through to the
  user's GitHub profile, and sender names above bubbles get a stable per-user
  color (matching their avatar hue), like group iMessage.
- **New issues** (⌘N): pick a repo (sorted by most recent chat activity,
  searchable), write title/body, toggle labels and assignees, drag images in.
- **Pin / Ignore** any chat (toolbar buttons or right-click). Ignored chats are
  muted: no notifications, no badge, tucked under the Ignored filter.
- **Closed issues auto-hide** once they're read and deselected (pinned ones
  stay). Flip "Show Closed Issues" in the filter menu to see everything;
  search always finds closed threads.
- **Notifications** for new messages and new issues in non-ignored chats, with
  inline reply straight from the notification. Opening a chat clears them.
- **Search** (⌘F) returns two sections, Messages-style: chats whose
  title/repo/author match, and every individual message containing the query
  (match shown bold in the preview). Clicking a message result opens its chat,
  scrolls to that exact message, and flashes a highlight ring on it.
- **Images** in conversations render inline; click one and it scales up into an
  in-window viewer (click anywhere, the ✕, or Esc to close; right-click for
  "Open in Browser"). Dragged-in images upload to **GitHub's own attachment
  storage** (`github.com/user-attachments`) — the same place the website puts
  them, so they stay as private as the repo they're posted to. GitHub has no
  token API for that host, so this rides a one-time in-app web sign-in (WebKit
  sheet; the session lives in the app's own cookie store and is kept fresh by
  use). A legacy fallback that commits images to a public
  `<you>/gitchat-assets` repo can be re-enabled in Settings.
- **Open in Safari** button in every chat jumps to the issue on github.com.
- Close/reopen issues, mark unread, launch at login, GitHub Enterprise base URL.

## Building

```bash
xcodebuild -project gitchat.xcodeproj -scheme gitchat -configuration Debug \
  -derivedDataPath build build
open build/Build/Products/Debug/gitchat.app
```

Or just open `gitchat.xcodeproj` in Xcode and hit Run.

## Signing in

Two options on the first-run screen:

1. **Use my GitHub CLI login** — one click if you have `gh` installed and
   authenticated.
2. **Personal access token** — the "Create a token on GitHub…" link opens the
   token page with the right scopes preselected (classic token, `repo` +
   `read:org`). Fine-grained tokens work too: grant Issues (read/write),
   Contents (read/write, for image uploads), and Metadata.

The token is stored in `~/Library/Application Support/gitchat/credentials.json`
with 0600 permissions (same trust model as the `gh` CLI's own config; Keychain
ACLs don't survive dev re-signing, which makes them miserable for a
locally-built app).

## How syncing works

- A cheap **firehose** call (`GET /issues?filter=all`) catches every updated
  issue across owned/member/org repos each cycle (default: every minute,
  configurable 30s–5m).
- A **round-robin sweep** re-checks a handful of individual repos per cycle
  (recently pushed ones first) to catch anything the firehose can't see.
- **Transcript backfill** quietly fetches full conversations so search and
  chat-opening feel instant.
- The first sync (default: last 30 days of issues, configurable) arrives marked
  read — no notification storm on install. After that, anything new from other
  people goes unread + notifies.
- Everything is cached in `~/Library/Application Support/gitchat/` as plain
  JSON; delete the folder to reset.

Pull requests are technically issues too — there's a Settings toggle to include
them (off by default).

## Layout

```
gitchat/
  main.swift            app entry (AppKit lifecycle)
  AppDelegate.swift     status item, windows, main menu
  AppState.swift        observable app state + sync loop + all user actions
  SyncEngine.swift      GitHub ops: transcripts, uploads, model building
  GitHubAPI.swift       REST client + wire types
  Store.swift           JSON persistence + search index
  Credentials.swift     token storage + gh CLI detection
  Notifier.swift        UNUserNotificationCenter wrapper (inline reply)
  ImageCache.swift      cached remote images, avatars
  Models.swift          Chat/Message/etc. + helpers
  Views/                SwiftUI: sidebar, transcript bubbles, composer,
                        new-issue sheet, login, settings
scripts/make_icon.swift regenerates the app icon into Assets.xcassets
```
