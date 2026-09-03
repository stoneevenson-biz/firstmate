#!/usr/bin/env bash
# fm-patch-lib.sh - build the review patch the Quarterdeck's foreign lens reads.
# Spec: docs/specs/2026-09-02-lens-patch-integrity.md. Source this, or ask it
# directly (see the CLI at the foot of this file).
#
# NEVER HAND OUT A PATCH THAT IS NOT A PATCH.
#
# The Quarterdeck has two halves. The independent verifier re-runs the gates in
# the worktree and reads whatever it likes; the foreign lens reads ONLY this
# file. So a payload that is not what the branch changed is not a weaker
# review - it is half a review of the wrong thing, and it looks exactly like a
# real one from the outside. On 2026-09-02 the lens on task fmcmd-guard was
# handed 200,000 bytes cut at an arbitrary byte: `git apply --check` called it
# `corrupt patch at line 3403`, it carried 7 commits when the branch owned 3,
# and it contained none of the branch's tests. That verdict was useful only
# because the lens said out loud that it could not read its own input.
#
# Three properties, in priority order, each with its own gate (gate-t4-lens-*):
#
#   1. SCOPE. The range is the branch's own base, not whatever ref is lying
#      around. See fm_patch_diff_base.
#   2. NO MID-PATCH TRUNCATION. A bound is honoured by dropping whole FILES,
#      never bytes, and every dropped file is named in the header with the
#      reason. A reviewer who knows what it did not see can weigh its own
#      verdict; one handed a silent truncation cannot.
#   3. FAIL CLOSED. The finished artifact is re-read with `git apply --check`.
#      If it does not pass, the caller refuses to run the lens at all rather
#      than reviewing rubbish - the loud degrade fm-lens-lib.sh already models.
#
# Properties 2 and 3 are belt and braces on purpose: splitting on file
# boundaries is what makes corruption impossible, and the apply check is what
# proves it for this particular artifact rather than assuming it.
#
# Outputs are globals, so a `set -e` caller can read them after a non-zero
# return: FM_PATCH_BASE, FM_PATCH_BASE_REF, FM_PATCH_TOTAL, FM_PATCH_INCLUDED,
# FM_PATCH_OMITTED, FM_PATCH_WHY.

FM_PATCH_BASE=""
FM_PATCH_BASE_REF=""
FM_PATCH_TOTAL=0
FM_PATCH_INCLUDED=0
FM_PATCH_OMITTED=""
FM_PATCH_WHY=""

# fm_patch_default_branch <worktree>: origin/HEAD's target, else main, else
# master. Prints the branch NAME (no refs/ prefix); non-zero when none resolves.
fm_patch_default_branch() {
  local wt=$1 ref branch
  ref=$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then printf '%s\n' "${ref#origin/}"; return 0; fi
  for branch in main master; do
    if git -C "$wt" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"; return 0
    fi
  done
  return 1
}

# fm_patch_configured_remotes <worktree>: the names of the remotes THIS CLONE
# configures, one per line. Local scope only, so a remote declared in a global
# or injected config is not mistaken for one of this clone's.
fm_patch_configured_remotes() {
  local wt=$1 key name
  while IFS= read -r key; do
    case "$key" in
      remote.*.url) : ;;
      *) continue ;;
    esac
    name=${key#remote.}
    name=${name%.url}
    [ -n "$name" ] && printf '%s\n' "$name"
  done <<EOF
$(git -C "$wt" config --local --name-only --get-regexp '^remote\..*\.url$' 2>/dev/null || true)
EOF
}

# fm_patch_diff_base <worktree> <default-branch> [hint-commit] [hint-ref]
#
# THE BRANCH'S OWN BASE, WHICH IS THE FURTHEST-FORWARD ONE, AND WHY THAT IS SAFE
# HERE AND NOWHERE ELSE IN fm-verify.
#
# fm-verify carries two bases and the difference is deliberate (see its own
# header). The AUTHORISATION base answers "was this declaration reviewed by
# somebody other than the crewmate?", which is a security question, so it is
# origin-only, fails closed, and explicitly refuses a furthest-forward rule: a
# pooled clone shares refs/heads/<default> with the primary checkout, so an
# ordinary local commit there would launder a self-authored declaration into an
# inherited one. That reasoning is not touched here and must not be.
#
# This is the DIFF base, and a patch file authorises nothing. Its only question
# is "how much of this branch is the branch's own work?", where taking the
# candidate that is FURTHEST FORWARD is exactly right: every commit it drops is
# one that some other default-branch ref already carries, so it was never this
# branch's to answer for. That is the fmcmd-guard defect precisely - the cached
# refs/remotes/origin/<default> was stale, the fetch that would have refreshed
# it did not land, and the merge base against that stale ref sat four already-
# merged commits behind the point the branch was actually cut from. The local
# refs/heads/<default> knew better and was never asked.
#
# The candidate set is deliberately narrow: default-branch-shaped refs only
# (refs/heads/<default> and refs/remotes/<remote>/<default>), never every ref in
# the repo. A sibling crewmate branch cut from THIS one would otherwise be a
# candidate whose merge base is one of our own commits, and moving the base
# forward onto it would hide our own work from the lens. Tags are skipped for
# the same reason plus cost.
#
# AND `refs/remotes/<anything>/<default>` IS NOT NARROW ENOUGH. A ref under
# refs/remotes/ is not evidence that a remote exists; it is just a ref, and the
# crewmate whose work is under review can write one. Reproduced 2026-09-02 in a
# repo with NO configured remotes at all:
#
#   git update-ref refs/remotes/fake/main "$(git rev-parse HEAD^)"
#
# moved the base one commit forward, and the patch handed to the lens dropped a
# commit and a file of the branch's own work while remaining a perfectly valid
# patch. That is the review artifact lying about what the branch changed - the
# same failure the byte truncation caused, reached by a different door, and this
# one is reachable BY THE AUTHOR OF THE CODE UNDER REVIEW.
#
# So a remote-tracking candidate counts only when its remote is one THIS CLONE
# CONFIGURES, read from local config (bin/fm-merge-target-lib.sh carries the
# long form of why a scope beats a name here). refs/heads/<default> needs no
# such proof: it is the clone's own branch, not a claim about a remote.
#
# The hint (fm-verify's authorisation base) seeds the search, so the result can
# only ever move forward from it, never behind it. A candidate that already
# contains HEAD is skipped: its merge base IS HEAD, which would leave an empty
# patch.
#
# Prints the base commit and sets FM_PATCH_BASE/FM_PATCH_BASE_REF; non-zero when
# no base resolves at all.
fm_patch_diff_base() {
  local wt=$1 default=$2 best=${3:-} best_ref=${4:-} head ref mb rest
  FM_PATCH_BASE=""
  FM_PATCH_BASE_REF=""
  head=$(git -C "$wt" rev-parse --verify --quiet HEAD) || return 1
  [ -n "$head" ] || return 1

  local cands=""
  if [ -n "$default" ] && git -C "$wt" show-ref --verify --quiet "refs/heads/$default"; then
    cands="refs/heads/$default"
  fi
  if [ -n "$default" ]; then
    local configured
    configured=" $(fm_patch_configured_remotes "$wt" | tr '\n' ' ')"
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      case "$ref" in
        refs/remotes/*/"$default") ;;
        *) continue ;;
      esac
      # Exactly one remote-name segment; refs/remotes/origin/x/<default> is a
      # branch called x/<default>, not the remote's default branch.
      rest=${ref#refs/remotes/}
      rest=${rest%"/$default"}
      case "$rest" in */*) continue ;; esac
      # ...and that segment must name a remote this clone configures.
      case "$configured" in *" $rest "*) : ;; *) continue ;; esac
      cands="$cands $ref"
    done <<EOF
$(git -C "$wt" for-each-ref --format='%(refname)' refs/remotes 2>/dev/null)
EOF
  fi

  # shellcheck disable=SC2086  # $cands is a deliberate word list of ref names
  for ref in $cands; do
    mb=$(git -C "$wt" merge-base HEAD "$ref" 2>/dev/null) || continue
    [ -n "$mb" ] || continue
    if [ "$mb" = "$head" ]; then continue; fi
    if [ -z "$best" ] || git -C "$wt" merge-base --is-ancestor "$best" "$mb" 2>/dev/null; then
      best=$mb
      best_ref=$ref
    fi
  done

  [ -n "$best" ] || return 1
  # shellcheck disable=SC2034  # consumed by sourcing callers (bin/fm-verify.sh)
  FM_PATCH_BASE=$best
  FM_PATCH_BASE_REF=$best_ref
  printf '%s\n' "$best"
}

# fm_patch_is_test_path <path>: does this path look like the branch's own test
# material? Used only for ORDERING (see fm_patch_build), never to include or
# exclude anything, so a false positive costs nothing but position.
fm_patch_is_test_path() {
  local p=$1 base
  case "/$p/" in
    */tests/*|*/test/*|*/spec/*|*/specs/*|*/e2e/*|*/__tests__/*) return 0 ;;
  esac
  base=${p##*/}
  case "$base" in
    *test*|*Test*|*spec*|*Spec*) return 0 ;;
  esac
  return 1
}

# fm_patch_check <worktree> <base-commit> <patch-file>
#
# `git apply --check` against a scratch index read from the base tree. Checking
# against an index rather than the working tree is what makes this answer a
# question about the PATCH: the worktree is at HEAD with the change already
# applied and may be dirty besides, so a plain --check there would fail on a
# perfectly good patch and pass on nothing useful.
#
# `--whitespace=nowarn` because the question is whether this is a PATCH, not
# whether the branch indents to a repo's taste: an `apply.whitespace = error`
# config would otherwise refuse the lens over trailing spaces.
#
# Sets FM_PATCH_WHY on refusal. Absolute <patch-file> please: git -C moves cwd.
fm_patch_check() {
  local wt=$1 base=$2 patch=$3 idx out rc=0
  FM_PATCH_WHY=""
  idx=$(mktemp) || { FM_PATCH_WHY="could not create a scratch index"; return 1; }
  if ! out=$(GIT_INDEX_FILE="$idx" git -C "$wt" read-tree "$base" 2>&1); then
    FM_PATCH_WHY="the base tree $base could not be read: $(printf '%s' "$out" | head -1)"
    rc=1
  elif ! out=$(GIT_INDEX_FILE="$idx" git -C "$wt" apply --cached --check --whitespace=nowarn "$patch" 2>&1); then
    FM_PATCH_WHY="git apply --check refused it: $(printf '%s' "$out" | head -1)"
    rc=1
  fi
  rm -f "$idx"
  return "$rc"
}

# fm_patch_build <worktree> <base-commit> <out-file> <max-bytes> [label] [base-ref]
#
# Writes a valid patch for <base>..HEAD to <out-file> and returns 0, or returns
# non-zero with FM_PATCH_WHY naming why no usable patch exists - in which case
# the caller must refuse the lens rather than hand it the file.
#
# THE BOUND IS SPENT ON WHOLE FILES, AND TESTS GO FIRST. Once a bound has to
# drop something, WHICH something is a review decision, not an accident of
# `git diff`'s path order - and that order is what silently dropped every
# tests/ path from the fmcmd-guard artifact, because tests sorts after bin and
# docs. A reviewer that cannot see the tests cannot judge whether the change is
# proven, which is the one question the Quarterdeck exists to ask, so test
# material is laid down first and everything else follows in path order.
#
# Binary files are named, never embedded: their content is worthless to a
# reviewer, and `Binary files ... differ` is not an appliable patch anyway.
#
# THE BOUND COVERS THE WHOLE PAYLOAD. An earlier round budgeted only the diff
# BODIES and then prepended a header carrying one line per commit and one line
# per omitted path - both unbounded. Measured: a 900-file branch under a
# 2000-byte bound produced an 81,411-byte payload, forty times the number it
# claimed, every byte of it header. A bound that the artifact does not obey is
# not a bound, and this one exists to protect the reviewer's context.
#
# So the budget is split before anything is written - a quarter to the header,
# the rest to the bodies - and the header stops adding lines when its share runs
# out, saying how many it elided. The split is fixed rather than clever: the
# header cannot spend what the bodies leave over, which wastes a little and is
# obviously terminating, where a negotiation between the two is neither. A
# finished payload that still exceeds the bound is a build FAILURE, so "a
# successful build never exceeds max" holds without qualification.
fm_patch_build() {
  # LC_ALL pinned for this function's own byte arithmetic: ${#line} counts
  # CHARACTERS under a UTF-8 locale, and a budget measured in characters is not
  # a budget measured in bytes. Not exported, so nothing this function runs sees it.
  local LC_ALL=C
  local wt=$1 base=$2 out=$3 max=$4 label=${5:-} base_ref=${6:-}
  local tmp body rec adds dels path tests others f size total=0 omitted="" tab
  local hdr hdr_budget body_budget hdr_used=0 hdr_elided=0 final
  tab=$(printf '\t')
  FM_PATCH_TOTAL=0
  FM_PATCH_INCLUDED=0
  FM_PATCH_OMITTED=""
  FM_PATCH_WHY=""

  tmp=$(mktemp -d) || { FM_PATCH_WHY="could not create a scratch directory"; return 1; }
  body="$tmp/body.patch"
  hdr="$tmp/header"
  : > "$body"
  : > "$hdr"
  hdr_budget=$(( max / 4 ))
  [ "$hdr_budget" -gt "$max" ] && hdr_budget=$max
  body_budget=$(( max - hdr_budget ))
  [ "$body_budget" -lt 0 ] && body_budget=0

  if ! git -C "$wt" diff --numstat --no-renames -z "$base" HEAD -- > "$tmp/numstat" 2>"$tmp/err"; then
    FM_PATCH_WHY="the range $base..HEAD could not be read: $(head -1 "$tmp/err")"
    rm -rf "$tmp"
    return 1
  fi

  # --numstat -z emits "<adds>\t<dels>\t<path>\0" per file; a binary file
  # reports "-" for both counts. --no-renames keeps it one path per record.
  # NUL all the way through. `--numstat -z` is read NUL-delimited because git
  # permits a newline INSIDE a path, and re-joining the two tiers with newlines
  # would split such a path back into two fragments that name no file - the
  # payload would then drop the real file and blame two inventions for it, which
  # is precisely the "you did not see this, and here is why" promise inverted.
  tests="$tmp/tier-tests"
  others="$tmp/tier-others"
  : > "$tests"
  : > "$others"
  while IFS= read -r -d '' rec; do
    [ -n "$rec" ] || continue
    adds=${rec%%"$tab"*}
    path=${rec#*"$tab"}
    dels=${path%%"$tab"*}
    path=${path#*"$tab"}
    [ -n "$path" ] || continue
    FM_PATCH_TOTAL=$((FM_PATCH_TOTAL + 1))
    if [ "$adds" = "-" ] && [ "$dels" = "-" ]; then
      omitted="$omitted$path - binary; its content is not embedded in a review patch"$'\n'
      continue
    fi
    if fm_patch_is_test_path "$path"; then
      printf '%s\0' "$path" >> "$tests"
    else
      printf '%s\0' "$path" >> "$others"
    fi
  done < "$tmp/numstat"
  cat "$tests" "$others" > "$tmp/order"

  f="$tmp/one.patch"
  while IFS= read -r -d '' path; do
    [ -n "$path" ] || continue
    if ! git -C "$wt" diff --no-renames "$base" HEAD -- ":(literal)$path" > "$f" 2>/dev/null; then
      omitted="$omitted$path - its diff could not be read"$'\n'
      continue
    fi
    size=$(wc -c < "$f" | tr -d ' ')
    if [ "$size" -eq 0 ]; then
      # numstat named it but the diff is empty. Nothing to review, but the
      # counts must still add up: silently dropping it would make the header's
      # own arithmetic a lie, which is the class of defect this file exists for.
      omitted="$omitted$path - git reported it changed but produced no diff for it"$'\n'
      continue
    fi
    if [ "$((total + size))" -gt "$body_budget" ]; then
      omitted="$omitted$path - $size bytes; including it would exceed the ${max}-byte payload bound"$'\n'
      continue
    fi
    cat "$f" >> "$body"
    total=$((total + size))
    FM_PATCH_INCLUDED=$((FM_PATCH_INCLUDED + 1))
  done < "$tmp/order"

  FM_PATCH_OMITTED=$omitted

  # The header is prose, every line commented, and it sits ahead of the first
  # `diff --git`: git apply skips leading text, and the `# ` prefix means no
  # line of it can ever be mistaken for patch content.
  #
  # hdr_put appends one line if the header's share of the budget can still hold
  # it, and counts it as elided otherwise. The 96-byte tail reserve is for the
  # elision notice itself, so the payload can always admit what it left out.
  hdr_put() {
    local line=$1 n=$(( ${#1} + 1 ))
    if [ "$(( hdr_used + n + 96 ))" -gt "$hdr_budget" ]; then
      hdr_elided=$(( hdr_elided + 1 ))
      return 0
    fi
    printf '%s\n' "$line" >> "$hdr"
    hdr_used=$(( hdr_used + n ))
  }

  # The three lines that make the payload self-describing go in unconditionally:
  # what it is, what range it covers, and what it does not contain. A payload
  # that could not afford to say that is refused below rather than shipped mute.
  {
    printf '# review patch%s\n' "${label:+ for $label}"
    printf '# range: %s..HEAD%s\n' "$base" "${base_ref:+ (base ref: $base_ref)}"
    printf '# files changed in this range: %s (included %s, omitted %s)\n' \
      "$FM_PATCH_TOTAL" "$FM_PATCH_INCLUDED" "$((FM_PATCH_TOTAL - FM_PATCH_INCLUDED))"
  } > "$hdr"
  hdr_used=$(wc -c < "$hdr" | tr -d ' ')

  hdr_put '# commits on this branch:'
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    hdr_put "#   $rec"
  done <<EOF
$(git -C "$wt" log --oneline "$base..HEAD" 2>/dev/null || true)
EOF

  if [ -n "$omitted" ]; then
    hdr_put '# OMITTED - the following files are NOT below; you have not seen them:'
    while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      hdr_put "#   $rec"
    done <<EOF
$(printf '%s' "$omitted")
EOF
    hdr_put '# Weigh your verdict accordingly: say so where an omitted file could change it.'
  fi
  if [ "$hdr_elided" -gt 0 ]; then
    printf '# %s further header line(s) elided to keep this payload inside its %s-byte bound.\n' \
      "$hdr_elided" "$max" >> "$hdr"
  fi
  printf '#\n' >> "$hdr"

  cat "$hdr" "$body" > "$out"

  if [ "$FM_PATCH_TOTAL" -eq 0 ]; then
    # An empty range is not a corrupt patch. There is nothing to apply and
    # nothing to check; the header says so and the lens can read that honestly.
    rm -rf "$tmp"
    return 0
  fi

  if [ "$FM_PATCH_INCLUDED" -eq 0 ]; then
    # Not always the bound: an asset-only branch changes nothing but binaries,
    # and those are never embedded. Either way there is no diff to review, so
    # the lens is refused rather than shown an empty artifact - but the reason
    # points at the payload's own omission block instead of guessing which
    # rule dropped what.
    FM_PATCH_WHY="every one of the $FM_PATCH_TOTAL changed files was omitted (bound ${max} bytes, binary content, or unreadable - the payload header names each one), so it carries no diff at all"
    rm -rf "$tmp"
    return 1
  fi

  final=$(wc -c < "$out" | tr -d ' ')
  if [ "$final" -gt "$max" ]; then
    # Only reachable when max is too small to hold even the three lines that
    # make the payload self-describing. Refusing keeps the invariant absolute:
    # a build that returns 0 has written a file of at most max bytes.
    FM_PATCH_WHY="the payload came to $final bytes against a ${max}-byte bound, which is too small to hold even the header that says what the patch covers"
    rm -rf "$tmp"
    return 1
  fi

  rm -rf "$tmp"
  fm_patch_check "$wt" "$base" "$out" || return 1
  return 0
}

# --- CLI ---------------------------------------------------------------------
# Ask the rule directly rather than restating it:
#   bash bin/fm-patch-lib.sh base  <worktree> [default-branch] [hint-commit]
#   bash bin/fm-patch-lib.sh build <worktree> <base> <out> [max-bytes]
#   bash bin/fm-patch-lib.sh check <worktree> <base> <patch-file>
# base/check exit 0 when they answer yes, 1 when they answer no.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -u
  _fm_patch_abs() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$(pwd)" "$1" ;; esac; }
  case "${1:-}" in
    base)
      _wt=${2:?usage: fm-patch-lib.sh base <worktree> [default-branch] [hint]}
      _def=${3:-$(fm_patch_default_branch "$_wt" || true)}
      if fm_patch_diff_base "$_wt" "$_def" "${4:-}"; then
        printf 'ref: %s\n' "${FM_PATCH_BASE_REF:-<none>}" >&2
        exit 0
      fi
      echo "no base resolves for $_wt" >&2
      exit 1
      ;;
    build)
      _wt=${2:?usage: fm-patch-lib.sh build <worktree> <base> <out> [max-bytes]}
      _base=${3:?missing base}
      _out=$(_fm_patch_abs "${4:?missing out}")
      if fm_patch_build "$_wt" "$_base" "$_out" "${5:-200000}" "$(basename "$_wt")"; then
        printf 'ok: %s files, %s included\n' "$FM_PATCH_TOTAL" "$FM_PATCH_INCLUDED"
        if [ -n "$FM_PATCH_OMITTED" ]; then printf 'omitted:\n%s' "$FM_PATCH_OMITTED"; fi
        exit 0
      fi
      printf 'unusable: %s\n' "$FM_PATCH_WHY" >&2
      exit 1
      ;;
    check)
      _wt=${2:?usage: fm-patch-lib.sh check <worktree> <base> <patch-file>}
      _base=${3:?missing base}
      _patch=$(_fm_patch_abs "${4:?missing patch}")
      if fm_patch_check "$_wt" "$_base" "$_patch"; then
        echo "valid patch"
        exit 0
      fi
      printf 'not a valid patch: %s\n' "$FM_PATCH_WHY" >&2
      exit 1
      ;;
    *)
      echo "usage: fm-patch-lib.sh <base|build|check> ..." >&2
      exit 2
      ;;
  esac
fi
