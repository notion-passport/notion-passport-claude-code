#!/bin/sh
# Manage project-local Notion MCP connections for Claude Code with the standard
# macOS/Linux tools. Servers change only through `claude mcp` at local scope.
# Never reads or writes OAuth tokens.
set -eu
umask 077

NOTION_URL=https://mcp.notion.com/mcp
MAX_ALIAS_LENGTH=40
BASE_CALLBACK_PORT=8123
project=.
dry_run=false
lock_dir=

usage() {
    cat <<'EOF'
Usage: sh notion-passport.sh [--project DIR] [--dry-run] COMMAND [ARGUMENT]

  add             Add a connection with an automatic directory-random alias
  list            Show aliases, server names, and the default connection
  default ALIAS   Choose the default connection for the routing skill
  remove ALIAS    Remove the server; OAuth credentials remain in Claude Code
  adopt SERVER    Manage an existing local-scope notion-* server of this project
  login ALIAS     Run Claude Code's interactive OAuth login in the project
  doctor          Check that Claude Code loads each connection

New aliases combine the project directory name with 8 random hex characters.
Each connection is the local-scope MCP server notion-ALIAS with its own fixed
OAuth callback port, the lowest one from 8123 that no server uses yet.
--dry-run supports add, remove, default and adopt, and changes nothing.

State: $CLAUDE_CONFIG_DIR/notion-passport/projects/KEY/{path,connections,default}
       ($CLAUDE_CONFIG_DIR defaults to ~/.claude)
Servers: local scope of this directory, changed only through `claude mcp`
Supported environments: macOS/Linux with sh, standard system utilities and claude.
EOF
}

die() { printf 'notion-passport: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ -n "$lock_dir" ]; then
        rm -f "$lock_dir/path" "$lock_dir/connections" "$lock_dir/default"
        rmdir "$lock_dir" 2>/dev/null || :
    fi
}
trap cleanup 0
trap 'exit 130' 1 2 3 15

while [ "$#" -gt 0 ]; do
    case "$1" in
        --project)
            [ "$#" -ge 2 ] || die '--project requires a directory'
            project=$2; shift 2 ;;
        --dry-run) dry_run=true; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option: $1" ;;
        *) break ;;
    esac
done
[ "$#" -gt 0 ] || { usage; exit 1; }
operation=$1
shift
case "$operation" in
    remove|default|login)
        [ "$#" -eq 1 ] || die "$operation requires one alias"
        alias=$1 ;;
    adopt)
        [ "$#" -eq 1 ] || die 'adopt requires one server name'
        case "$1" in notion-*) alias=${1#notion-} ;; *) die 'adopt requires a notion-ALIAS server name' ;; esac ;;
    add|list|doctor)
        [ "$#" -eq 0 ] || die "$operation takes no arguments"
        alias= ;;
    *) die "unknown command: $operation" ;;
esac
if "$dry_run"; then
    case "$operation" in add|remove|default|adopt) ;; *) die '--dry-run supports add, remove, default and adopt' ;; esac
fi

valid_alias() {
    case "$1" in ''|*[!a-z0-9_-]*|-*|_*) return 1 ;; esac
    [ "${#1}" -le "$MAX_ALIAS_LENGTH" ]
}
[ -z "$alias" ] || valid_alias "$alias" || die 'invalid alias or server name; see --help'
case "$project" in -*) project=./$project ;; esac
project=$(CDPATH= cd -P "$project" && pwd -P) || die 'project directory does not exist'
cd "$project"
# Claude Code keeps local-scope servers per absolute path, so state follows the same key.
claude_json=${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json
project_key=$(printf '%s' "$project" | cksum | awk '{ print $1 "-" $2 }')
state_dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/notion-passport/projects/$project_key
path_file=$state_dir/path
connections_file=$state_dir/connections
default_file=$state_dir/default

check_paths() {
    for path in "$state_dir" "$path_file" "$connections_file" "$default_file"; do
        [ ! -L "$path" ] || die "refusing a symbolic link: $path"
    done
    [ ! -e "$state_dir" ] || [ -d "$state_dir" ] || die "not a directory: $state_dir"
    for path in "$path_file" "$connections_file" "$default_file"; do
        [ ! -e "$path" ] || [ -f "$path" ] || die "not a regular file: $path"
    done
}

load_state() {
    default_alias=
    if [ -f "$path_file" ]; then
        [ "$(cat "$path_file")" = "$project" ] || die "state belongs to another directory: $state_dir"
    fi
    if [ -f "$connections_file" ]; then
        awk -v maxalias="$MAX_ALIAS_LENGTH" '
            !/^[a-z0-9][a-z0-9_-]*$/ || length($0)>maxalias || seen[$0]++ { exit 1 }
        ' "$connections_file" || die 'invalid connections file'
    fi
    if [ -f "$default_file" ]; then
        default_alias=$(cat "$default_file")
        valid_alias "$default_alias" || die 'invalid default alias file'
    fi
}

random_hex() {
    [ -r /dev/urandom ] || die '/dev/urandom is required on this platform'
    hex=$(od -An -N "$1" -tx1 /dev/urandom | tr -d ' \n')
    case "$hex" in ''|*[!a-f0-9]*) die 'could not generate a random ID' ;; esac
    [ "${#hex}" -eq "$(( $1 * 2 ))" ] || die 'could not generate a random ID'
    printf '%s\n' "$hex"
}

server_for() { printf 'notion-%s\n' "$1"; }

aliases() {
    [ -f "$connections_file" ] || return 0
    cat "$connections_file"
}

has_alias() {
    [ -f "$connections_file" ] || return 1
    awk -v name="$1" '$0==name { found=1 } END { exit !found }' "$connections_file"
}

# True when any project's config already mentions the server name.
claude_knows() {
    [ -f "$claude_json" ] || return 1
    awk -v name="\"$1\"" 'index($0, name) { found=1 } END { exit !found }' "$claude_json"
}

new_alias() {
    directory_name=${project##*/}
    stem=$(printf '%s' "$directory_name" |
        LC_ALL=C tr '[:upper:]' '[:lower:]' |
        LC_ALL=C tr -cs 'a-z0-9_-' '-' |
        LC_ALL=C awk -v limit="$((MAX_ALIAS_LENGTH - 9))" '
            { stem=substr($0, 1, limit); gsub(/^[-_]+|[-_]+$/, "", stem); print stem }
        ')
    [ -n "$stem" ] || stem=project
    attempt=0
    while [ "$attempt" -lt 32 ]; do
        alias=$stem-$(random_hex 4)
        if ! has_alias "$alias" && ! claude_knows "$(server_for "$alias")"; then
            return 0
        fi
        attempt=$((attempt + 1))
    done
    die 'could not generate an unused connection alias'
}

# Every server keeps its own OAuth callback port, so skip ports any project uses.
free_port() {
    if [ -f "$claude_json" ]; then
        awk '{
            line=$0
            while (match(line, /"callbackPort"[[:space:]]*:[[:space:]]*[0-9]+/)) {
                value=substr(line, RSTART, RLENGTH)
                sub(/^[^:]*:[[:space:]]*/, "", value)
                print value
                line=substr(line, RSTART+RLENGTH)
            }
        }' "$claude_json"
    fi | awk -v port="$BASE_CALLBACK_PORT" '{ used[$0]=1 } END { while (port in used) port++; print port }'
}

require_claude() { command -v claude >/dev/null 2>&1 || die 'claude is not on PATH'; }

acquire_lock() {
    mkdir -p "$state_dir"
    if ! mkdir "$state_dir/lock" 2>/dev/null; then
        die "another update is running, or a stale lock exists: $state_dir/lock"
    fi
    lock_dir=$state_dir/lock
    check_paths
    load_state
}

save_connections() {
    cat > "$lock_dir/connections"
    if [ ! -f "$path_file" ]; then
        printf '%s\n' "$project" > "$lock_dir/path"
        mv "$lock_dir/path" "$path_file"
    fi
    if [ -s "$lock_dir/connections" ]; then
        mv "$lock_dir/connections" "$connections_file"
    else
        rm -f "$lock_dir/connections" "$connections_file"
    fi
}

write_default() {
    if [ -n "$1" ]; then
        printf '%s\n' "$1" > "$lock_dir/default"
        mv "$lock_dir/default" "$default_file"
    else
        rm -f "$default_file"
    fi
}

check_paths
load_state

case "$operation" in
    add)
        "$dry_run" || { require_claude; acquire_lock; }
        new_alias
        server=$(server_for "$alias")
        port=$(free_port)
        if "$dry_run"; then
            printf 'Would run in %s:\n' "$project"
            printf 'claude mcp add --transport http --scope local --callback-port %s %s %s\n' "$port" "$server" "$NOTION_URL"
            printf 'Generated alias and port shown for preview only; no connection was saved.\n'
            exit 0
        fi
        if ! output=$(claude mcp add --transport http --scope local --callback-port "$port" "$server" "$NOTION_URL" 2>&1); then
            printf '%s\n' "$output" >&2
            die 'claude mcp add failed; no connection was saved'
        fi
        { aliases; printf '%s\n' "$alias"; } | save_connections
        if [ -z "$default_alias" ]; then write_default "$alias"; fi
        printf 'Added %s -> %s (OAuth callback port %s)\n' "$alias" "$server" "$port"
        printf 'Authenticate in Claude Code: /mcp -> %s -> Authenticate\n' "$server"
        ;;
    list)
        printf 'ALIAS\tSERVER\tDEFAULT\n'
        aliases | while IFS= read -r connection; do
            selected=
            [ "$connection" != "$default_alias" ] || selected=yes
            printf '%s\t%s\t%s\n' "$connection" "$(server_for "$connection")" "$selected"
        done
        ;;
    default)
        "$dry_run" || acquire_lock
        has_alias "$alias" || die "no connection named $alias"
        if "$dry_run"; then printf 'Would set default connection: %s\n' "$alias"; exit 0; fi
        write_default "$alias"
        printf 'Default connection: %s\n' "$alias"
        ;;
    remove)
        "$dry_run" || { require_claude; acquire_lock; }
        if ! has_alias "$alias"; then printf 'No connection named %s; nothing changed.\n' "$alias"; exit 0; fi
        server=$(server_for "$alias")
        if "$dry_run"; then printf 'Would remove connection: %s -> %s\n' "$alias" "$server"; exit 0; fi
        if claude mcp get "$server" >/dev/null 2>&1; then
            if ! output=$(claude mcp remove --scope local "$server" 2>&1); then
                printf '%s\n' "$output" >&2
                die "claude mcp remove failed; $alias is still listed"
            fi
        else
            printf 'Claude Code no longer has %s; removing it from the list only.\n' "$server"
        fi
        aliases | awk -v name="$alias" '$0!=name' | save_connections
        if [ "$default_alias" = "$alias" ]; then
            remaining=$(aliases | awk 'NR==1 { print; exit }')
            write_default "$remaining"
        fi
        printf 'Removed %s. Claude Code OAuth credentials were retained.\n' "$alias"
        ;;
    adopt)
        require_claude
        "$dry_run" || acquire_lock
        server=$(server_for "$alias")
        if has_alias "$alias"; then printf 'Already managed: %s -> %s\n' "$alias" "$server"; exit 0; fi
        details=$(claude mcp get "$server" 2>&1) || die "Claude Code has no server named $server in this directory"
        case "$details" in *'Scope: Local config'*) ;; *) die "$server is not a local-scope server of this directory" ;; esac
        case "$details" in *"URL: $NOTION_URL"*) ;; *) die "$server does not use $NOTION_URL" ;; esac
        if "$dry_run"; then printf 'Would manage existing connection: %s -> %s\n' "$alias" "$server"; exit 0; fi
        { aliases; printf '%s\n' "$alias"; } | save_connections
        if [ -z "$default_alias" ]; then write_default "$alias"; fi
        printf 'Now managing %s -> %s. Its OAuth credentials are unchanged.\n' "$alias" "$server"
        ;;
    login)
        has_alias "$alias" || die "no connection named $alias"
        require_claude
        server=$(server_for "$alias")
        claude mcp get "$server" >/dev/null 2>&1 || die "Claude Code cannot find $server in this directory; run doctor"
        claude mcp login "$server"
        ;;
    doctor)
        if [ -n "$default_alias" ]; then
            has_alias "$default_alias" || die 'the default alias does not refer to an existing connection'
        fi
        require_claude
        connections=$(aliases)
        [ -n "$connections" ] || die 'no managed connections; run add or adopt first'
        status=0
        for connection in $connections; do
            server=$(server_for "$connection")
            if details=$(claude mcp get "$server" 2>&1); then
                state=$(printf '%s\n' "$details" | awk '
                    /^[[:space:]]*Status:/ { sub(/^[[:space:]]*Status:[[:space:]]*/, ""); print; exit }')
                printf 'OK: %s -> %s loads in Claude Code (%s)\n' "$connection" "$server" "${state:-status unknown}"
            else
                printf 'FAIL: %s -> %s is not configured for this directory\n' "$connection" "$server" >&2
                status=1
            fi
        done
        printf 'The workspace each connection reaches is chosen at authentication; confirm it with a read-only request.\n'
        exit "$status"
        ;;
esac
