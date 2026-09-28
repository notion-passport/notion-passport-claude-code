#!/bin/sh
# Native shell checks against a stub claude CLI: servers change only through
# `claude mcp`, per-directory state stays consistent, and failures change nothing.
set -eu

test_root=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd -P)
script=${NOTION_PASSPORT_TEST_SCRIPT:-$test_root/plugins/notion-passport-claude-code/scripts/notion-passport.sh}
script_shell=${NOTION_PASSPORT_TEST_SHELL:-sh}
fixture=$(mktemp -d "${TMPDIR:-/tmp}/notion-passport-tests.XXXXXX")
trap 'rm -rf "$fixture"' 0
trap 'exit 130' 1 2 3 15
fixture=$(CDPATH= cd -P "$fixture" && pwd -P)

CLAUDE_CONFIG_DIR=$fixture/claude
NOTION_PASSPORT_TEST_LOG=$fixture/claude.log
export CLAUDE_CONFIG_DIR NOTION_PASSPORT_TEST_LOG
claude_json=$CLAUDE_CONFIG_DIR/.claude.json
url=https://mcp.notion.com/mcp
mkdir -p "$CLAUDE_CONFIG_DIR" "$fixture/bin"
: > "$NOTION_PASSPORT_TEST_LOG"

# The stub keeps one server per line of .claude.json; directory "*" is user scope.
cat > "$fixture/bin/claude" <<'EOF'
#!/bin/sh
store=$CLAUDE_CONFIG_DIR/.claude.json
printf '%s\n' "$*" >> "$NOTION_PASSPORT_TEST_LOG"
[ -f "$store" ] || : > "$store"
[ "$1" = mcp ] || exit 2
command=$2
shift 2
eval "name=\${$#}"
cwd=$(pwd -P)
find_server() {
    awk -F '"' -v cwd="$cwd" -v name="$name" '($4==cwd || $4=="*") && $8==name { print; found=1 } END { exit !found }' "$store"
}
case "$command" in
    add)
        port=
        while [ "$#" -gt 2 ]; do
            case "$1" in --callback-port) port=$2; shift 2 ;; *) shift ;; esac
        done
        name=$1
        [ -z "${NOTION_PASSPORT_TEST_FAIL_ADD-}" ] || { echo 'simulated add failure' >&2; exit 1; }
        if find_server > /dev/null; then echo "MCP server $name already exists in local config" >&2; exit 1; fi
        printf '{"projects": {"%s": {"mcpServers": {"%s": {"type": "http", "url": "%s", "oauth": {"callbackPort": %s}}}}}}\n' \
            "$cwd" "$name" "$2" "$port" >> "$store"
        echo "Added HTTP MCP server $name" ;;
    remove)
        line=$(find_server) || { echo "No MCP server named \"$name\" in local scope" >&2; exit 1; }
        case "$line" in *'{"*":'*) echo "No MCP server named \"$name\" in local scope" >&2; exit 1 ;; esac
        awk -F '"' -v cwd="$cwd" -v name="$name" '!($4==cwd && $8==name)' "$store" > "$store.new"
        mv "$store.new" "$store" ;;
    get)
        line=$(find_server) || { echo "No MCP server named \"$name\"." >&2; exit 1; }
        scope='Local config (private to you in this project)'
        case "$line" in *'{"*":'*) scope='User config (available in all your projects)' ;; esac
        printf '%s:\n  Scope: %s\n  Status: ! Needs authentication\n  Type: http\n  URL: %s\n' \
            "$name" "$scope" "$(printf '%s\n' "$line" | awk -F '"' '{ print $16 }')" ;;
    login)
        find_server > /dev/null || exit 1
        echo "Authenticated $name" ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$fixture/bin/claude"
PATH="$fixture/bin:$PATH"

project=$fixture/project\ with\ spaces
mkdir -p "$project"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run() { "$script_shell" "$script" --project "$project" "$@"; }
expect_failure() {
    if run "$@" > "$fixture/output" 2>&1; then fail "expected failure: $*"; fi
}
last_alias() { run list | awk -F '\t' 'NR>1 { alias=$1 } END { print alias }'; }
state_dir() {
    for dir in "$CLAUDE_CONFIG_DIR"/notion-passport/projects/*; do
        [ "$(cat "$dir/path" 2>/dev/null)" != "$project" ] || { printf '%s\n' "$dir"; return 0; }
    done
    fail "no state for $project"
}
seed() {
    printf '{"projects": {"%s": {"mcpServers": {"%s": {"type": "http", "url": "%s", "oauth": {"callbackPort": %s}}}}}}\n' \
        "$1" "$2" "$3" "$4" >> "$claude_json"
}
port_of() { awk -F '"' -v name="$1" '$8==name { sub(/^[^0-9]*/, "", $21); print $21 + 0 }' "$claude_json"; }

# Another project already owns callback port 8123.
seed /elsewhere notion-elsewhere-0123abcd "$url" 8123
cp "$claude_json" "$fixture/original"

run --dry-run add > "$fixture/output"
[ ! -e "$CLAUDE_CONFIG_DIR/notion-passport" ] || fail 'dry-run created state'
[ ! -s "$NOTION_PASSPORT_TEST_LOG" ] || fail 'dry-run called claude'
cmp "$fixture/original" "$claude_json" || fail 'dry-run changed Claude Code config'

run add > "$fixture/output"
first=$(last_alias)
run add > "$fixture/output"
second=$(last_alias)
[ "$first" != "$second" ] || fail 'repeated add reused the connection alias'
for connection in "$first" "$second"; do
    case "$connection" in project-with-spaces-*) ;; *) fail 'alias does not include the sanitized directory name' ;; esac
    suffix=${connection##*-}
    case "$suffix" in *[!a-f0-9]*) fail 'alias suffix is not hex' ;; esac
    [ "${#suffix}" -eq 8 ] || fail 'alias suffix is not 8 characters'
done
[ "$(port_of "notion-$first")" -eq 8124 ] || fail 'first connection did not skip the used port'
[ "$(port_of "notion-$second")" -eq 8125 ] || fail 'second connection did not take the next free port'
grep -Fqx "mcp add --transport http --scope local --callback-port 8124 notion-$first $url" "$NOTION_PASSPORT_TEST_LOG" ||
    fail 'add did not go through claude mcp at local scope'
cp "$claude_json" "$fixture/two-connections"
run add > "$fixture/output"
third=$(last_alias)
[ "$third" != "$first" ] && [ "$third" != "$second" ] || fail 'third connection was not distinct'
run remove "$third" > "$fixture/output"
cmp "$fixture/two-connections" "$claude_json" || fail 'adding and removing a connection changed existing ones'
run list > "$fixture/list"
awk -F '\t' -v first="$first" -v second="$second" '
    $1==first { personal=1; p=$2; if ($3=="yes") selected=1 }
    $1==second { work=1; w=$2 }
    END { exit !(personal && work && selected && p!=w) }' "$fixture/list" || fail 'connections not distinct'

run default "$second" > "$fixture/output"
[ "$(cat "$(state_dir)/default")" = "$second" ] || fail 'default not saved'
run --dry-run remove "$first" > "$fixture/output"
cmp "$fixture/two-connections" "$claude_json" || fail 'remove dry-run changed config'
run remove "$first" > "$fixture/output"
run list > "$fixture/list"
awk -F '\t' -v first="$first" -v second="$second" '
    $1==first { bad=1 } $1==second && $3=="yes" { good=1 }
    END { exit !(!bad && good) }' "$fixture/list" || fail 'removal affected the other connection'
run remove "$second" > "$fixture/output"
cmp "$fixture/original" "$claude_json" || fail 'unmanaged config was not preserved'
[ ! -e "$(state_dir)/default" ] || fail 'removed default was retained'

run add > "$fixture/output"
first=$(last_alias)
[ "$(port_of "notion-$first")" -eq 8124 ] || fail 'freed callback port was not reused'
run add > "$fixture/output"
second=$(last_alias)
run remove "$first" > "$fixture/output"
[ "$(cat "$(state_dir)/default")" = "$second" ] || fail 'default fallback did not select remaining connection'

expect_failure add personal
expect_failure default 'bad alias'
expect_failure remove '../escape'
expect_failure default missing
expect_failure adopt not-notion
expect_failure --dry-run list

mkdir "$(state_dir)/lock"
expect_failure add
rmdir "$(state_dir)/lock"

# A failed claude call leaves the connection list unchanged.
run list > "$fixture/before"
cp "$claude_json" "$fixture/before-config"
if (NOTION_PASSPORT_TEST_FAIL_ADD=1; export NOTION_PASSPORT_TEST_FAIL_ADD; run add) > "$fixture/output" 2>&1; then
    fail 'failed claude add was reported as success'
fi
run list > "$fixture/after"
cmp "$fixture/before" "$fixture/after" || fail 'failed claude add changed the connection list'
cmp "$fixture/before-config" "$claude_json" || fail 'failed claude add changed config'

run login "$second" > "$fixture/output"
grep -Fqx "mcp login notion-$second" "$NOTION_PASSPORT_TEST_LOG" || fail 'login did not use the connection server'
run doctor > "$fixture/output"
grep -F "OK: $second -> notion-$second" "$fixture/output" | grep -Fq 'Needs authentication' || fail 'doctor did not report status'

# A server removed outside this script fails doctor and can still be unlisted.
awk -F '"' -v name="notion-$second" '$8!=name' "$claude_json" > "$fixture/edited"
cp "$fixture/edited" "$claude_json"
if run doctor > "$fixture/output" 2>&1; then fail 'doctor passed with a missing server'; fi
run remove "$second" > "$fixture/output"
run list > "$fixture/list"
[ "$(wc -l < "$fixture/list")" -eq 1 ] || fail 'externally removed server stayed listed'

# Servers made by 0.0.x keep their names and credentials when adopted.
seed "$project" notion-project-with-spaces-ab12 "$url" 8130
seed "*" notion-user-scope "$url" 8131
seed "$fixture/other" notion-other-ab12 "$url" 8132
seed "$project" notion-not-notion "https://example.com/mcp" 8133
cp "$claude_json" "$fixture/before-adopt"
run --dry-run adopt notion-project-with-spaces-ab12 > "$fixture/output"
run list > "$fixture/list"
[ "$(wc -l < "$fixture/list")" -eq 1 ] || fail 'adopt dry-run saved a connection'
run adopt notion-project-with-spaces-ab12 > "$fixture/output"
run adopt notion-project-with-spaces-ab12 > "$fixture/output"
run list > "$fixture/list"
awk -F '\t' '$1=="project-with-spaces-ab12" && $2=="notion-project-with-spaces-ab12" && $3=="yes" { found++ }
    END { exit found!=1 }' "$fixture/list" || fail 'adopted connection not listed once as default'
expect_failure adopt notion-user-scope
expect_failure adopt notion-other-ab12
expect_failure adopt notion-not-notion
expect_failure adopt notion-missing
cmp "$fixture/before-adopt" "$claude_json" || fail 'adopt changed Claude Code config'

# State of one directory is invisible from another.
other=$fixture/other
mkdir "$other"
[ "$("$script_shell" "$script" --project "$other" list | wc -l)" -eq 1 ] || fail 'state leaked into another directory'

# State under a different key is refused rather than trusted.
key_dir=$(state_dir)
printf '%s\n' /somewhere/else > "$key_dir/path"
expect_failure list
printf '%s\n' "$project" > "$key_dir/path"

mv "$key_dir/connections" "$fixture/symlink-target"
ln -s "$fixture/symlink-target" "$key_dir/connections"
cp "$fixture/symlink-target" "$fixture/symlink-original"
expect_failure add
cmp "$fixture/symlink-original" "$fixture/symlink-target" || fail 'symlink target changed'
rm "$key_dir/connections"
mv "$fixture/symlink-target" "$key_dir/connections"

# A random suffix used by any project must be retried.
project=$fixture/renamed-project
mkdir "$project"
taken=0123abcd
next_suffix=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
while [ "$next_suffix" = "$taken" ]; do
    next_suffix=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
done
seed /elsewhere "notion-renamed-project-$taken" "$url" 8140
cat > "$fixture/bin/od" <<'EOF'
#!/bin/sh
if [ ! -f "$NOTION_PASSPORT_COLLISION_MARKER" ]; then
    : > "$NOTION_PASSPORT_COLLISION_MARKER"
    printf '%s\n' "$NOTION_PASSPORT_COLLISION_FIRST"
else
    printf '%s\n' "$NOTION_PASSPORT_COLLISION_NEXT"
fi
EOF
chmod +x "$fixture/bin/od"
(
    NOTION_PASSPORT_COLLISION_MARKER=$fixture/collision-marker
    NOTION_PASSPORT_COLLISION_FIRST=$taken
    NOTION_PASSPORT_COLLISION_NEXT=$next_suffix
    export NOTION_PASSPORT_COLLISION_MARKER NOTION_PASSPORT_COLLISION_FIRST NOTION_PASSPORT_COLLISION_NEXT
    run add
) > "$fixture/output"
rm "$fixture/bin/od"
[ "$(last_alias)" = "renamed-project-$next_suffix" ] || fail 'random suffix collision was not retried'

# Directory names need to remain valid aliases even when long or entirely non-ASCII.
project=$fixture/ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-long-directory
mkdir "$project"
run add > "$fixture/output"
generated=$(last_alias)
[ "${#generated}" -eq 40 ] || fail 'long directory name was not bounded'
case "$generated" in abcdefghijklmnopqrstuvwxyz01234-*) ;; *) fail 'long directory name not normalized correctly' ;; esac

project=$fixture/노션
mkdir "$project"
run add > "$fixture/output"
generated=$(last_alias)
case "$generated" in project-*) ;; *) fail 'non-ASCII directory name has no valid fallback' ;; esac

printf 'PASS: automatic aliases, callback ports, random collision retry, path normalization,\n'
printf '      multiple connections, dry-run, config preservation, defaults, invalid input,\n'
printf '      locking, failed claude calls, login, doctor, external removal, adoption,\n'
printf '      per-directory state and symlinks\n'
