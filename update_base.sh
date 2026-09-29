#!/bin/bash
# update_base.sh — sync new LineageOS lineage-22.2 base into the AstralOS tree
# Usage: ./update_base.sh [--one <path>]
set -u
ROOT=/home/olaffx/android/lineage
SNAP_FILE="$ROOT/.base_snapshot"
LOG=/tmp/opencode/sync.log
PATCHDIR=/tmp/opencode/basepatch
mkdir -p /tmp/opencode "$PATCHDIR"

if [ "${1:-}" = "--one" ]; then
    ROOT="${ROOT}"
else
    : > "$LOG"
fi

SNAP=$(cat "$SNAP_FILE" 2>/dev/null || echo "2026-09-19T08:13:51+02:00")

# Repos we modified (squashed history with AstralOS changes) -> patch method
PATCH_REPOS="frameworks/base|vendor/lineage|device/xiaomi/miatoll|bootable/recovery|lineage-sdk|packages/apps/Settings|packages/apps/Trebuchet|packages/apps/SetupWizard|packages/apps/Backgrounds|packages/apps/LineageParts"

is_patch_repo() { case "|$PATCH_REPOS|" in *"|$1|"*) return 0;; esac; return 1; }

# ---------- build project table from updated manifest ----------
build_table() {
    python3 - << 'EOF' > /tmp/opencode/projects.tsv 2>/tmp/opencode/parse.err
import xml.etree.ElementTree as ET

M = '.repo/manifests/'
projects, seen = [], set()

def parse(fn, d_rev, d_remotes):
    root = ET.parse(M + fn).getroot()
    d = root.find('default')
    if d is not None:
        d_rev = d.get('revision', d_rev)
        if d.get('remote'):
            d_remotes = dict(d_remotes)
            d_remotes['_default'] = d.get('remote')
    remotes = dict(d_remotes)
    for r in root.findall('remote'):
        remotes[r.get('name')] = (r.get('fetch', ''), r.get('revision') or d_rev)
    def_remote = d_remotes.get('_default', '')
    for p in root.findall('project'):
        path = p.get('path') or p.get('name')
        if path in seen:
            continue
        seen.add(path)
        remote = p.get('remote') or def_remote
        rev = p.get('revision') or (remotes.get(remote, ('', d_rev))[1] or d_rev)
        fetch = remotes.get(remote, ('', ''))[0]
        projects.append((path, p.get('name'), rev, remote, fetch))
    for inc in root.findall('include'):
        parse(inc.get('name'), d_rev, {'_default': def_remote, **{k: v for k, v in remotes.items()}})

parse('default.xml', '', {})
# local roomservice manifests (device/kernel)
for fn in ('local_manifests/roomservice.xml',):
    try:
        root = ET.parse('.repo/' + fn).getroot()
    except Exception:
        continue
    for p in root.findall('project'):
        path = p.get('path') or p.get('name')
        if path in seen:
            continue
        seen.add(path)
        remote = p.get('remote') or 'github'
        fetch = '..' if remote == 'github' else ''
        rev = p.get('revision') or 'refs/heads/lineage-22.2'
        projects.append((path, p.get('name'), rev, remote, fetch))

for row in projects:
    print('\t'.join(x or '' for x in row))
EOF
    [ -s /tmp/opencode/parse.err ] && cat /tmp/opencode/parse.err >&2
}

url_for() { # name fetch
    case "$2" in
        "") echo "";;
        "..") echo "https://github.com/$1";;
        *://*) echo "${2%/}/$1";;
        /*) echo "${2%/}/$1";;
        *) echo "https://github.com/$1";;
    esac
}

# ---------- generic ref sync for pristine repos ----------
sync_ref() {
    local path=$1 name=$2 url=$3 ref=$4
    cd "$ROOT" || return
    [ -d "$path/.git" ] || [ -f "$path/.git" ] || { echo "SKIP-nogit $path" >> "$LOG"; return; }
    [ -n "$url" ] || { echo "SKIP-nourl $path" >> "$LOG"; return; }
    if [ -z "$ref" ]; then echo "SKIP-noref $path" >> "$LOG"; return; fi
    case "$ref" in
        refs/*) ;;
        *[!0-9a-f]*|"") ref="refs/heads/$ref";;
        *) ;;  # 40-char hex = commit SHA, fetch as-is
    esac
    if ! git -C "$path" fetch --quiet --no-tags "$url" "$ref" 2>>"$LOG"; then
        echo "FETCHFAIL $path ($ref)" >> "$LOG"; return
    fi
    local FETCH HEAD
    FETCH=$(git -C "$path" rev-parse 'FETCH_HEAD^{commit}') || { echo "SKIP $path" >> "$LOG"; return; }
    HEAD=$(git -C "$path" rev-parse HEAD)
    [ "$FETCH" = "$HEAD" ] && { echo "UPTODATE $path" >> "$LOG"; return; }
    if git -C "$path" merge --ff-only --quiet FETCH_HEAD 2>>"$LOG"; then
        echo "FF $path" >> "$LOG"; return
    fi
    local dirty; dirty=$(git -C "$path" status --porcelain | wc -l)
    if [ "$dirty" = "0" ]; then
        if git -C "$path" reset --hard --quiet FETCH_HEAD 2>>"$LOG"; then
            echo "RESET $path" >> "$LOG"
        else
            echo "RESETFAIL $path" >> "$LOG"
        fi
        return
    fi
    if git -C "$path" stash push --quiet -u -m base-sync 2>>"$LOG"; then
        if git -C "$path" merge --ff-only --quiet FETCH_HEAD 2>>"$LOG" \
           || git -C "$path" reset --hard --quiet FETCH_HEAD 2>>"$LOG"; then
            if git -C "$path" stash pop --quiet 2>>"$LOG"; then
                echo "DIRTY-FF $path" >> "$LOG"
            else
                echo "STASH-CONFLICT $path (stash kept)" >> "$LOG"
            fi
        else
            echo "DIRTY-CONFLICT $path" >> "$LOG"
        fi
    else
        echo "STASHFAIL $path" >> "$LOG"
    fi
}

# ---------- our modified repos: upstream diff -> apply ----------
patch_modified() {
    local path=$1 name=$2 url=$3
    cd "$ROOT" || return
    [ -n "$url" ] || { echo "SKIP-noupstream $path" >> "$LOG"; return; }
    if ! git -C "$path" fetch --quiet --shallow-since=2026-09-01 "$url" refs/heads/lineage-22.2 2>>"$LOG"; then
        # shallow-since can fail on some repos: fall back to full fetch
        if ! git -C "$path" fetch --quiet "$url" refs/heads/lineage-22.2 2>>"$LOG"; then
            echo "FETCHFAIL $path" >> "$LOG"; return
        fi
    fi
    local OLD NEW
    OLD=$(git -C "$path" rev-list -1 --before="$SNAP" FETCH_HEAD)
    NEW=$(git -C "$path" rev-parse 'FETCH_HEAD^{commit}')
    if [ -z "$OLD" ]; then echo "NOBASE $path" >> "$LOG"; return; fi
    if [ "$OLD" = "$NEW" ]; then echo "UPTODATE $path" >> "$LOG"; return; fi
    local slug patch
    slug=$(echo "$path" | tr / _)
    patch="$PATCHDIR/$slug.patch"
    git -C "$path" diff --binary "$OLD" "$NEW" > "$patch"
    if git -C "$path" apply --check "$patch" 2>/dev/null; then
        git -C "$path" apply "$patch" && echo "APPLIED $path ($(git -C "$path" diff --stat | tail -1 | sed 's/^ *//'))" >> "$LOG"
        return
    fi
    if git -C "$path" apply --reverse --check "$patch" 2>/dev/null; then
        echo "ALREADY-APPLIED $path" >> "$LOG"; return
    fi
    git -C "$path" apply --reject "$patch" >/dev/null 2>>"$LOG"
    local nrej; nrej=$(find "$path" -name "*.rej" | wc -l)
    echo "REJECTED $path ($nrej hunks; patch: $patch)" >> "$LOG"
    find "$path" -name "*.rej" >> "$LOG"
}

if [ "${1:-}" = "--one" ]; then
    # args: --one <path> <name> <url> <ref>
    sync_ref "$2" "$3" "$4" "$5"
    exit 0
fi

# ---------- main ----------
cd "$ROOT"
echo "snapshot cutoff: $SNAP"

echo "== Step 1: sync manifest =="
if git -C "$ROOT/.repo/manifests" fetch --quiet origin lineage-22.2 2>>"$LOG"; then
    if ! git -C "$ROOT/.repo/manifests" merge --ff-only --quiet FETCH_HEAD 2>>"$LOG"; then
        git -C "$ROOT/.repo/manifests" reset --hard --quiet FETCH_HEAD 2>>"$LOG" \
            && echo "manifest updated (reset)" \
            || echo "MANIFEST-CONFLICT"
    else
        echo "manifest updated"
    fi
    git -C "$ROOT/.repo/manifests" log -1 --oneline | cut -c1-80
else
    echo "MANIFEST-FETCHFAIL"; exit 1
fi

echo "== Step 2: rebuild project table =="
build_table
echo "$(wc -l < /tmp/opencode/projects.tsv) projects"

echo "== Step 3: patch our modified repos =="
: > /tmp/opencode/phase_m.list
while IFS=$'\t' read -r path name rev remote fetch; do
    is_patch_repo "$path" && printf '%s\t%s\t%s\n' "$path" "$name" "$(url_for "$name" "$fetch")" >> /tmp/opencode/phase_m.list
done < /tmp/opencode/projects.tsv
while IFS=$'\t' read -r path name url; do
    patch_modified "$path" "$name" "$url" &
    while [ "$(jobs -rp | wc -l)" -ge 4 ]; do wait -n; done
done < /tmp/opencode/phase_m.list
wait

echo "== Step 4: sync all other repos =="
awk -F'\t' '{print $1"\t"$2"\t"$3"\t"$5}' /tmp/opencode/projects.tsv \
    | while IFS=$'\t' read -r path name rev fetch; do
        is_patch_repo "$path" && continue
        url=$(url_for "$name" "$fetch")
        printf '%s %s %s %s\n' "$path" "$name" "$url" "$rev"
      done > /tmp/opencode/phase_p.list
echo "$(wc -l < /tmp/opencode/phase_p.list) repos to sync"

xargs -a /tmp/opencode/phase_p.list -n4 -P 12 "$0" --one

wait
echo "== Summary =="
grep -cE "^(FF|DIRTY-FF|RESET|APPLIED) " "$LOG" | xargs echo "updated:"
grep -cE "^(UPTODATE|ALREADY-APPLIED)" "$LOG" | xargs echo "already current:"
if grep -qE "^(FETCHFAIL|RESETFAIL|REJECTED|STASH-CONFLICT|DIRTY-CONFLICT|STASHFAIL|NOBASE|MANIFEST-CONFLICT)" "$LOG"; then
    echo "PROBLEMS:"
    grep -E "^(FETCHFAIL|RESETFAIL|REJECTED|STASH-CONFLICT|DIRTY-CONFLICT|STASHFAIL|NOBASE|MANIFEST-CONFLICT)" "$LOG"
    echo "snapshot marker NOT advanced"
else
    date "+%Y-%m-%dT%H:%M:%S%z" > "$SNAP_FILE"
    echo "no failures; snapshot marker: $(cat "$SNAP_FILE")"
fi
