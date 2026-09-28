---
name: setup-notion-workspace
description: >-
  Add and manage project-local Notion MCP connections with independent OAuth.
  Use for connecting this directory to Notion, adding another account or
  workspace, listing connections, authenticating, choosing a default connection,
  removing a connection, or taking over a connection made by an earlier version.
  Applies to requests such as "connect this project to Notion", "이 프로젝트에
  노션 연결", "노션 워크스페이스 추가", "프로젝트별 노션 연결", and "노션 mcp
  프로젝트별로 분리", even when MCP is not mentioned. For reading or editing
  Notion content through existing connections, use use-notion-workspace.
---

# Set up Notion connections

Run the plugin script against the user's target directory, defaulting to the
current working directory. The script uses macOS/Linux system tools and the
`claude` CLI.

```sh
sh "${CLAUDE_PLUGIN_ROOT}/scripts/notion-passport.sh" --project "<target-directory>" list
```

Each connection is a local-scope MCP server named `notion-<alias>`: it is stored
in Claude Code's config for that directory only, not committed to git, and has
its own fixed OAuth callback port. Claude Code keeps OAuth tokens per server
name, so each connection authenticates separately.

- To add a new connection, run `add` with no argument. Each invocation creates a
  separate connection with an automatic directory-and-random alias. Capture the
  alias and server name from the output. If an operation fails, inspect `list`
  before retrying so that a completed addition is not duplicated.
- To authenticate, the user opens `/mcp`, selects the new server and chooses
  **Authenticate**. Alternatively run `login <alias>` from the same target
  directory; it opens a browser and waits for the result. The browser's Notion
  account and workspace selection determines what this connection can access;
  its generated alias does not select a workspace. Let the user complete the
  interactive authorization.
- Earlier versions of this plugin created one server per directory, named like
  `notion-<directory>-<4 hex>`, and did not record it. When `list` lacks such a
  server that `claude mcp list` shows for this directory, run `adopt <server>`.
  It keeps the server name, so its authentication and workspace carry over.
- Use `doctor` to check that Claude Code loads each connection and to see its
  authentication status. It does not show which workspace was chosen; verify
  that with a read-only MCP request when the server's tools are available.
- Use `default <alias>` to record the connection used by the content-routing
  skill. This does not change any other Notion server.
- On a request to remove a connection, use `remove <alias>`. It removes the
  local-scope server and retains OAuth credentials. If the user requests logout
  as well, run `claude mcp logout <server-name>` in the target directory before
  removing the connection.

Pass `--dry-run` before `add`, `remove`, `default`, or `adopt` when the user
wants a preview. Prefer the script over running `claude mcp add` or `remove`
yourself or editing `~/.claude.json`. The shared `notion` plugin and the
claude.ai Notion connector can coexist with these connections; do not uninstall
them as part of project setup.

If a server added during a session is missing from `/mcp`, or its tools stay
unavailable after authentication, restart Claude Code in the target directory.
