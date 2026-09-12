#!/usr/bin/env bash
#
# inventory-gates.sh -- regenerate (or --check) the machine-generated gate
# fleet inventory (M40 GF1, issue #934; fleet section M40 GF5, issue #940).
#
# Every executable script directly under tools/ gets one row: line count,
# class (A/B/C/D/tooling -- explicit exceptions below, prefix defaults
# otherwise), registration status (just recipe? in the spec-dir class-B
# fleet? status.md row?), and a one-line purpose scraped from its own
# header comment. A gate-class script registered nowhere is listed as an
# ORPHAN. Since GF5 the class-B fleet itself is discovered from
# tools/gate/specs/ via tools/gate/fleet.sh and rendered as its own
# section -- the same list the vz-gates.yml CI shards consume.
#
# Usage:
#   bash tools/inventory-gates.sh          # rewrite docs/gate-fleet-inventory.md
#   bash tools/inventory-gates.sh --check  # fail (rc=1) if the tracked file
#                                          # differs from a fresh render --
#                                          # this is the registration guard:
#                                          # a new script changes the render,
#                                          # so it fails until the report is
#                                          # regenerated and committed.
#   just inventory-gates [--check]
#
# Deterministic by construction: no dates, no revisions, no host state, and
# -- since issue #1177 -- a LOCALE PIN, so a fresh render on a clean tree is
# byte-identical in every environment.
#
# Locale pin (issue #1177): the render used to depend on the ambient locale.
# `cut -c1-100` counts BYTES under LC_ALL=C (the common macOS shell default
# for scripts) but CHARACTERS under a UTF-8 locale, so a header containing a
# non-ASCII character -- e.g. live-m21-persist-title-orphan.spec's em dash --
# rendered differently in the two environments: `--check` failed for whoever
# was not in the same locale as the author, and `[[:space:]]` in the trailing
# sed was locale-sensitive too. LC_ALL=C is now pinned for the whole render
# (byte-deterministic sorting/comparison), and header truncation is done by
# `truncate_chars` in UTF-8 CHARACTERS rather than bytes -- byte truncation
# can also split a multi-byte sequence and write invalid UTF-8 into a tracked
# markdown file. `--check` additionally asserts render equality across two
# locales, so a future locale-sensitive operation cannot creep back in.
#
set -euo pipefail

export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REPORT="docs/gate-fleet-inventory.md"
CHECK=0
[ "${1:-}" = "--check" ] || true
if [ "${1:-}" = "--check" ]; then CHECK=1; fi

class_of() {
    case "$1" in
        # Class C (interactive) -- gate-inventory.md non-gate registers.
        verify-pointer-manual.sh) echo "C"; return ;;
        # Class D (diagnostics, not gates).
        verify-preexit-tx.sh|verify-tx-diag.sh|verify-tx-transition.sh|\
        verify-fw-mmu-capture.sh|verify-t0sz16-walkprobe.sh|verify-t0sz16.sh|\
        audit-vz-irq-api.sh|probe-pointer-routes.sh|test-unicode-torture.sh) echo "D"; return ;;
        # Class B without the verify-live- prefix.
        verify-bad-handoff.sh|verify-marker.sh|verify-nvram-console.sh|\
        verify-host-console.sh|verify-custom-virtio.sh|verify-cvc-echo.sh|\
        verify-zc-corpus.sh) echo "B"; return ;;
        # Class A without the live prefix (portable / CI).
        verify-transcript.sh|verify-unit-tests.sh|verify-mmu-debt.sh|\
        verify-bss-budget.sh|verify-mutations.sh|verify-glyph-raster.sh|\
        verify-ttf-fonts.sh|verify-vf-class-a.sh|check-zc-host-contract.py) echo "A"; return ;;
        verify-live-*.sh) echo "B"; return ;;
        verify-*.sh) echo "A"; return ;;
        *) echo "tooling"; return ;;
    esac
}

# truncate_chars N -- copy stdin to stdout, keeping at most N UTF-8
# CHARACTERS (not bytes). Explicit and locale-proof: python3 decodes UTF-8
# itself, so neither the ambient locale nor a split multi-byte sequence can
# change the result. Readers/writers are the raw byte streams on purpose --
# python's text mode would pick up the very locale we are pinning away from.
truncate_chars() {
    python3 -c '
import sys
limit = int(sys.argv[1])
text = sys.stdin.buffer.read().decode("utf-8", "replace")
sys.stdout.buffer.write(text[:limit].encode("utf-8"))
' "$1"
}

# First "# text" header line (or """docstring opener for .py) in the
# first 12 lines; truncated, pipe-escaped for the markdown table.
purpose_of() {
    awk 'NR<=12 {
        if ($0 ~ /^# [^ ]/) { sub(/^# /, ""); print; exit }
        if ($0 ~ /^"""/) { sub(/^"""/, ""); print; exit }
    }' "$1" | truncate_chars 110 | sed 's/|/\\|/g; s/[[:space:]]*$//'
}

has_just() {
    local name="${1%.sh}"
    name="${name%.py}"
    grep -q "^${name}:" justfile 2>/dev/null
}

render_to() {
    local out="$1"
    local total=0 orphans=0
    local orphan_list="" rows=""
    local nA=0 nB=0 nC=0 nD=0 nT=0 just_yes=0 flt_yes=0 ci_yes=0 st_yes=0

    # The class-B fleet, discovered from the spec dir (GF5). One
    # "kind<TAB>id" line per member; consumed for the fleet section and
    # the per-script fleet column.
    local fleet_tsv="$(mktemp "${TMPDIR:-/tmp}/fleet-tsv.XXXXXX")"
    bash "$ROOT/tools/gate/fleet.sh" list > "$fleet_tsv"

    while IFS= read -r f; do
        base="$(basename "$f")"
        lines="$(wc -l < "$f" | tr -d ' ')"
        cls="$(class_of "$base")"
        total=$((total + 1))
        case "$cls" in
            A) nA=$((nA+1)) ;; B) nB=$((nB+1)) ;; C) nC=$((nC+1)) ;;
            D) nD=$((nD+1)) ;; *) nT=$((nT+1)) ;;
        esac
        if has_just "$base"; then j="y"; just_yes=$((just_yes+1)); else j="n"; fi
        if awk -F'\t' -v id="${base%.sh}" -v py="${base%.py}" \
                '$2==id || $2==py { found=1 } END { exit !found }' "$fleet_tsv"; then
            fl="y"; flt_yes=$((flt_yes+1)); else fl="n"; fi
        if grep -qF "tools/$base" .github/workflows/*.yml 2>/dev/null; then
            c="y"; ci_yes=$((ci_yes+1)); else c="n"; fi
        if grep -qF "$base" docs/status.md 2>/dev/null; then
            s="y"; st_yes=$((st_yes+1)); else s="n"; fi
        pur="$(purpose_of "$f")"
        [ -n "$pur" ] || pur="(no header line)"
        if { [ "$cls" = "A" ] || [ "$cls" = "B" ] || [ "$cls" = "C" ] || [ "$cls" = "D" ]; } \
            && [ "$j" = "n" ] && [ "$fl" = "n" ] && [ "$c" = "n" ] && [ "$s" = "n" ]; then
            orphans=$((orphans+1))
            orphan_list="${orphan_list}${base}"$'\n'
        fi
        rows="${rows}| \`$base\` | $lines | $cls | $j | $fl | $c | $s | $pur |"$'\n'
    done <<EOF
$(LC_ALL=C ls tools/*.sh tools/*.py 2>/dev/null | LC_ALL=C sort)
EOF

    {
        echo "# Gate fleet inventory (generated)"
        echo
        echo "> Machine-generated by \`bash tools/inventory-gates.sh\` (M40 GF1,"
        echo "> issue #934). **Do not hand-edit** -- re-render instead. The"
        echo "> \`--check\` mode fails when the tracked file drifts from a fresh"
        echo "> render, so every new script under \`tools/\` must arrive with a"
        echo "> regenerated report. Subdirectory tooling (\`lib/\`, \`status/\`,"
        echo "> \`context/\`, \`gate/\`, \`ragshit/\`) is summarized below, not rowed."
        echo
        echo "## Summary"
        echo
        echo "| metric | count |"
        echo "|---|---|"
        echo "| top-level scripts (\`tools/*.sh\` + \`tools/*.py\`) | $total |"
        echo "| class A (portable / CI) | $nA |"
        echo "| class B (VZ hardware gate) | $nB |"
        echo "| class C (interactive) | $nC |"
        echo "| class D (diagnostic) | $nD |"
        echo "| tooling (not gates) | $nT |"
        echo "| with a just recipe | $just_yes |"
        echo "| in the class-B fleet (spec dir / legacy script) | $flt_yes |"
        echo "| named in a GitHub workflow | $ci_yes |"
        echo "| named in docs/status.md | $st_yes |"
        echo "| **orphans (gate-class, registered nowhere)** | **$orphans** |"
        echo
        echo "## Subdirectory tooling (not gates)"
        echo
        echo "| dir | files | role |"
        echo "|---|---|---|"
        for d in lib status context ragshit gate; do
            n="$(find "tools/$d" -type f 2>/dev/null | wc -l | tr -d ' ')"
            case "$d" in
                lib) r="per-run isolation for live gates (\`gate-run.sh\`)" ;;
                status) r="multiagent coordination gate + claim tooling (class A)" ;;
                context) r="context snapshot helpers" ;;
                gate) r="M40 vgate harness + specs (GF2+)" ;;
                ragshit) r="host-side context engine (developer tooling, not guest software)" ;;
            esac
            echo "| \`tools/$d/\` | $n | $r |"
        done
        echo
        echo "## Class-B fleet (discovered from the spec dir)"
        echo
        echo "> M40 GF5 (issue #940): this section IS the fleet inventory -- the"
        echo "> exact list \`bash tools/gate/fleet.sh list\` produces and the"
        echo "> vz-gates.yml CI shards consume. A spec added under"
        echo "> tools/gate/specs/ appears here (and in just + CI) with zero list"
        echo "> edits; the --check mode fails until the report is regenerated."
        echo
        echo "Members: every \`tools/gate/specs/*.spec\` (run through"
        echo "\`tools/gate/vgate.sh\`) plus the four legacy class-B scripts. The"
        echo "interactive serial-takeover gate (\`zig build run\`, needs a TTY) is"
        echo "deliberately not part of the automated fleet. Run one with"
        echo "\`just gate <id>\`, a pattern group with \`just gates <pattern>\`, all"
        echo "of them with \`just verify-vz\`."
        echo
        echo "| kind | id | runs / asserts | spec header |"
        echo "|---|---|---|---|"
        while IFS=$'\t' read -r k id; do
            if [ "$k" = spec ]; then
                spec="$ROOT/tools/gate/specs/$id.spec"
                na="$(grep -c '^vgate_assert ' "$spec" || true)"
                nr="$(grep -c '^vgate_run ' "$spec" || true)"
                hdr="$(grep -m1 '^# ' "$spec" | sed 's/^# //' | truncate_chars 100 | sed 's/|/\\|/g; s/[[:space:]]*$//')"
                [ -n "$hdr" ] || hdr="(no header comment)"
                echo "| spec | \`$id\` | ${nr:-0} run / ${na:-0} assert | $hdr |"
            else
                echo "| script | \`$id\` | (legacy script) | \`tools/$id.sh\` |"
            fi
        done < "$fleet_tsv"
        echo
        echo "## Orphans"
        echo
        if [ "$orphans" -eq 0 ]; then
            echo "None -- every gate-class script is registered somewhere."
        else
            echo "Gate-class scripts with no just recipe, no fleet membership, and no"
            echo "status.md row:"
            echo
            printf '%s' "$orphan_list" | sed 's/^/- `/' | sed 's/$/`/'
        fi
        echo
        echo "## All top-level scripts"
        echo
        echo "Columns: \`just\` = justfile recipe of the same name; \`fleet\` = in"
        echo "the spec-dir class-B fleet (\`tools/gate/fleet.sh list\`); \`ci\` ="
        echo "named in \`.github/workflows/*.yml\`; \`st\` = named in"
        echo "\`docs/status.md\` (\`y\` = yes, \`n\` = no throughout)."
        echo
        echo "| script | lines | class | just | fleet | ci | st | purpose |"
        echo "|---|---|---|---|---|---|---|---|"
        printf '%s' "$rows"
    } > "$out"
    rm -f "${fleet_tsv:-}"
}

if [ "$CHECK" -eq 1 ]; then
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/inv-check.XXXXXX")"
    tmp="$tmpdir/report.md"
    render_to "$tmp"
    rc=0
    if cmp -s "$tmp" "$REPORT"; then
        echo "inventory-gates --check: OK ($REPORT matches a fresh render)"
    else
        echo "inventory-gates --check: FAIL -- $REPORT drifted from a fresh render."
        echo "Run 'bash tools/inventory-gates.sh' (or 'just inventory-gates') and commit the result."
        diff -u "$REPORT" "$tmp" | head -30 || true
        rc=1
    fi
    # Locale invariance (issue #1177): the render must be byte-identical when
    # the ambient locale differs. Plain `render_to` already pins LC_ALL=C, so
    # render the second copy with a UTF-8 locale forced for the whole pass --
    # if any operation is still locale-sensitive, the two diverge here instead
    # of in a contributor's shell.
    # NOTE: `locale -a | grep -q ...` is a trap under `set -o pipefail` --
    # grep leaves early on the match, the producer takes SIGPIPE, and the
    # pipeline reports failure, so the probe silently reads "not installed".
    # Feed grep from a here-string (no second process, no pipe to break).
    probe="en_US.UTF-8"
    if grep -qixE 'en_US\.utf-?8' <<< "$(locale -a 2>/dev/null || true)"; then
        ( export LC_ALL="$probe" LC_CTYPE="$probe"; render_to "$tmpdir/report-utf8.md" )
        if cmp -s "$tmp" "$tmpdir/report-utf8.md"; then
            echo "inventory-gates --check: OK (render is locale-invariant: LC_ALL=C == $probe)"
        else
            echo "inventory-gates --check: FAIL -- the render depends on the locale."
            echo "A locale-sensitive operation crept back into render_to; diff (C vs $probe):"
            diff -u "$tmp" "$tmpdir/report-utf8.md" | head -30 || true
            rc=1
        fi
    else
        echo "inventory-gates --check: NOTE -- $probe not installed on this host; " \
             "the two-locale invariance check was skipped (the render is still LC_ALL-pinned)"
    fi
    rm -rf "$tmpdir"
    exit "$rc"
else
    render_to "$REPORT"
    echo "wrote $REPORT"
fi
