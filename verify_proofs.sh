#!/usr/bin/env bash
# verify_proofs.sh — check ./solutions against official miniF2F statements via
# leanprover/comparator. Pass = proof closes the verbatim upstream statement
# (vendor/miniF2F submodule), axioms ⊆ permitted, kernel-checked.
#
# Usage:
#   ./verify_proofs.sh [-j N] [folder]   # default folder solutions, jobs nproc
#   ./verify_proofs.sh clean [folder]    # wipe ./work first
#   ./verify_proofs.sh --7z FILE         # verify .lean from a 7z/zip (prompts
#                                        # password; prefer AES-256, not ZipCrypto)
#   ENABLE_NANODA=1 ./verify_proofs.sh   # + nanoda kernel cross-check
#
# Needs: submodule inited, elan/lean/lake, git, curl, jq, go; ~6 GB; net on first run.

set -euo pipefail

trap 'trap - INT TERM; kill 0 2>/dev/null; exit 130' INT TERM

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINIF2F_DIR="$ROOT/vendor/miniF2F"

# Pinned to 4.29, not the submodule's 4.27: comparator 2a00b30's lean4export
# only reads 4.29 oleans; FC from the Iteron-dev fork. Override via env:
# LEAN_TOOLCHAIN/MATHLIB_REV/FC_REPO/FC_REV.
[[ -f "$MINIF2F_DIR/lean-toolchain" ]] || {
  printf 'miniF2F submodule missing — run: git submodule update --init vendor/miniF2F\n' >&2; exit 1; }
LEAN_TOOLCHAIN="${LEAN_TOOLCHAIN:-leanprover/lean4:v4.29.0}"

COMPARATOR_REPO="https://github.com/leanprover/comparator.git"
COMPARATOR_REV="2a00b30"
PERMITTED_AXIOMS="${PERMITTED_AXIOMS:-propext Quot.sound Classical.choice}"
ENABLE_NANODA="${ENABLE_NANODA:-0}"
JOBS="${JOBS:-$(nproc)}"

WORK="$ROOT/work"; VERIFY="$WORK/verify"; COMPDIR="$WORK/comparator"; BIN="$WORK/bin"

usage(){ printf 'usage: %s [-j N|--jobs N] [--7z FILE] [clean] [folder]   (default folder: solutions)\n' "${0##*/}"; }
CLEAN=0; folder=""; archive=""
while (( $# )); do case "$1" in
  -j|--jobs) JOBS="${2:?-j needs a number}"; shift 2;;
  -j*)       JOBS="${1#-j}"; shift;;
  --jobs=*)  JOBS="${1#*=}"; shift;;
  --7z)      archive="${2:?--7z needs a file}"; shift 2;;
  --7z=*)    archive="${1#*=}"; shift;;
  clean|--clean) CLEAN=1; shift;;
  -h|--help) usage; exit 0;;
  *)         folder="$1"; shift;;
esac; done
(( CLEAN )) && rm -rf "$WORK"
if [[ -n "$archive" ]]; then
  [[ -z "$folder" ]] || { printf -- '--7z and folder are mutually exclusive\n' >&2; exit 1; }
  [[ -f "$archive" ]] || { printf 'archive not found: %s\n' "$archive" >&2; exit 1; }
  command -v 7z >/dev/null || { printf 'missing tool: 7z — sudo apt install 7zip\n' >&2; exit 1; }
  folder="$WORK/zip_solutions"; rm -rf "$folder"; mkdir -p "$folder"
  read -rsp "Password for ${archive##*/} (empty if unencrypted): " ZIP_PW; printf '\n'
  7z e -y ${ZIP_PW:+-p"$ZIP_PW"} -o"$folder" "$archive" '*.lean' -r >/dev/null \
    || { printf '7z extraction failed (wrong password?)\n' >&2; exit 1; }
  rm -f "$folder"/._*
fi
FOLDER="$(cd "${folder:-$ROOT/solutions}" && pwd)"

R=$'\033[0m'; B=$'\033[1;34m'; G=$'\033[1;32m'; X=$'\033[1;31m'; Y=$'\033[1;33m'
say(){ printf '\n%s── %s%s\n' "$B" "$*" "$R"; }
die(){ printf '%s✗ %s%s\n' "$X" "$*" "$R" >&2; exit 1; }
bar(){
  local d=$1 t=$2 lbl=${3:-} w=34 i f=$(( $1*34/$2 )) g='' e=''
  for((i=0;i<f;i++)); do g+='█'; done; for((i=f;i<w;i++)); do e+='░'; done
  printf '\r\033[K  [%s%s%s%s] %3d%% %d/%d  %s' "$G" "$g" "$R" "$e" $(( d*100/t )) "$d" "$t" "$lbl"
}
count(){ ls "$1" 2>/dev/null | wc -l; }

say "Prerequisites"
for t in elan lean lake git curl jq; do command -v "$t" >/dev/null || die "missing tool: $t"; done
if (( ENABLE_NANODA )); then
  command -v nanoda_bin >/dev/null || die "ENABLE_NANODA=1 but 'nanoda_bin' not on PATH — build nanoda_lib (cargo build --release) and add target/release to PATH"
fi
MATHLIB_REV="${MATHLIB_REV:-8a178386ffc0f5fef0b77738bb5449d50efeea95}"  # mathlib4 tag v4.29.0
FC_REPO="${FC_REPO:-https://github.com/Iteron-dev/formal-conjectures.git}"
FC_REV="${FC_REV:-a5c76d7e696cd25156b250fb89086e6774e2d370}"             # fork branch 4.29
MINIF2F_COMMIT="$(git -C "$MINIF2F_DIR" rev-parse HEAD)"
mkdir -p "$WORK" "$BIN" "$VERIFY" "$WORK/cfg" "$WORK/cmod"
printf '  %s\n' "$(elan --version 2>/dev/null)"
printf '  miniF2F %s (Lean %s / Mathlib %s)\n' "${MINIF2F_COMMIT:0:9}" "$LEAN_TOOLCHAIN" "${MATHLIB_REV:0:9}"

say "Lean project (Lean $LEAN_TOOLCHAIN / Mathlib ${MATHLIB_REV:0:9} / formal_conjectures ${FC_REV:0:9})"
printf '%s\n' "$LEAN_TOOLCHAIN" > "$VERIFY/lean-toolchain"

MLMAN="$WORK/mathlib-manifest-${MATHLIB_REV:0:12}.json"
[[ -s "$MLMAN" ]] || curl -fsSL \
  "https://raw.githubusercontent.com/leanprover-community/mathlib4/$MATHLIB_REV/lake-manifest.json" \
  -o "$MLMAN" || die "cannot fetch mathlib lake-manifest for $MATHLIB_REV"
{
cat <<EOF
name = "verify"
defaultTargets = ["Solution"]

[[require]]
name = "mathlib"
git = "https://github.com/leanprover-community/mathlib4.git"
rev = "$MATHLIB_REV"

[[require]]
name = "formal_conjectures"
git = "$FC_REPO"
rev = "$FC_REV"
EOF
jq -r '.packages[] | "\n[[require]]\nname = \"\(.name)\"\ngit = \"\(.url)\"\nrev = \"\(.rev)\""' "$MLMAN"
cat <<EOF

# Trusted Challenge modules: official statements, verbatim from the submodule.
[[lean_lib]]
name = "MiniF2F"
globs = ["MiniF2F.*"]

[[lean_lib]]
name = "Solution"
globs = ["Solution.*"]
EOF
} > "$VERIFY/lakefile.toml"

mkdir -p "$VERIFY/MiniF2F"
cp "$MINIF2F_DIR/MiniF2F/ProblemImports.lean" "$VERIFY/MiniF2F/ProblemImports.lean"
cp "$MINIF2F_DIR/MiniF2F/Test.lean"           "$VERIFY/MiniF2F/Test.lean"
cp "$MINIF2F_DIR/MiniF2F/Valid.lean"          "$VERIFY/MiniF2F/Valid.lean"

if [[ ! -f "$VERIFY/lake-manifest.json" || ! -d "$VERIFY/.lake/packages/mathlib" || ! -d "$VERIFY/.lake/packages/formal_conjectures" ]] \
   || ! cmp -s "$VERIFY/lakefile.toml" "$WORK/lakefile.stamp"; then
  ( cd "$VERIFY" && lake update )
  cp "$VERIFY/lakefile.toml" "$WORK/lakefile.stamp"
fi
( cd "$VERIFY" && lake exe cache get >/dev/null )
printf '  %s\n  Mathlib cache ready\n' "$(cd "$VERIFY" && lake --version)"

say "comparator $COMPARATOR_REV + lean4export"
[[ -d "$COMPDIR/.git" ]] || git clone --filter=blob:none "$COMPARATOR_REPO" "$COMPDIR"
(
  cd "$COMPDIR"
  git checkout -q "$COMPARATOR_REV"
  [[ -x .lake/build/bin/comparator ]] || lake build
  lake build lean4export/lean4export >/dev/null 2>&1 || true
)
COMP="$COMPDIR/.lake/build/bin/comparator"
L4X="$(find "$COMPDIR/.lake" -type f -name lean4export | head -1)"
[[ -x "$COMP" ]] || die "comparator binary not built"
[[ -n "$L4X" ]] || die "lean4export binary not built"


LANDRUN_DIR="$WORK/landrun"; LRBIN="$LANDRUN_DIR/landrun"
if [[ ! -x "$LRBIN" ]]; then
  command -v go >/dev/null || { [[ -x "$HOME/.local/go/bin/go" ]] && export PATH="$HOME/.local/go/bin:$PATH"; }
  command -v go >/dev/null || die "go toolchain required to build landrun — install Go and re-run"
  [[ -d "$LANDRUN_DIR/.git" ]] || git clone --depth 1 https://github.com/Zouuup/landrun.git "$LANDRUN_DIR"
  ( cd "$LANDRUN_DIR" && CGO_ENABLED=0 go build -o "$LRBIN" ./cmd/landrun ) || die "landrun build failed"
fi
ln -sf "$LRBIN" "$BIN/landrun"
ln -sf "$L4X" "$BIN/lean4export"

LEANBIN="$(cd "$VERIFY" && lean --print-prefix)/bin"
export PATH="$LEANBIN:$BIN:$PATH"
export LEAN_PATH="$(cd "$VERIFY" && lake env printenv LEAN_PATH)"
printf '  landrun + comparator + lean4export ready\n'

# Solutions name their theorem FI.Root.<id>, not the bare <id> comparator
# matches on. Find the qualified name so we can alias <id> to it.
alias_target(){
  awk -v id="$2" '
    $1=="namespace"{ ns[++depth]=$2; next }
    $1=="end"{ if(depth>0) depth--; next }
    ($1=="theorem"||$1=="lemma"){
      name=$2; sub(/[(:{].*/,"",name)
      if(name==id){
        pfx=""; for(k=1;k<=depth;k++) pfx=(pfx==""?ns[k]:pfx"."ns[k])
        fq=(pfx==""?name:pfx"."name)
        if(fq==id) bare=1; else qual=fq
      }
    }
    END{ print (bare?"":qual) }
  ' "$1"
}

say "Installing solutions from $FOLDER"
shopt -s nullglob
files=("$FOLDER"/*.lean)
(( ${#files[@]} )) || die "no .lean files in $FOLDER"
mkdir -p "$VERIFY/Solution"
rm -f "$VERIFY/Solution/"*.lean
stems=(); challenge_mods=(); aliased=()
for f in "${files[@]}"; do
  s="$(basename "$f" .lean)"; stems+=("$s")
  cp "$f" "$VERIFY/Solution/$s.lean"
  tgt="$(alias_target "$VERIFY/Solution/$s.lean" "$s")"
  if [[ -n "$tgt" ]]; then
    printf '\nalias _root_.%s := %s\n' "$s" "$tgt" >> "$VERIFY/Solution/$s.lean"
    aliased+=("$s")
  fi
  if grep -qE "^theorem ${s}( |\(|:|\{|$)" "$VERIFY/MiniF2F/Test.lean"; then
    cmod="MiniF2F.Test"
  elif grep -qE "^theorem ${s}( |\(|:|\{|$)" "$VERIFY/MiniF2F/Valid.lean"; then
    cmod="MiniF2F.Valid"
  else
    die "no official miniF2F statement named '$s' in Test or Valid — solution does not match a benchmark problem"
  fi
  challenge_mods+=("$cmod")
  printf '%s\n' "$cmod" > "$WORK/cmod/$s"
done
total=${#stems[@]}
(( ${#aliased[@]} )) && printf '  %saliased %d namespaced id(s):%s %s\n' "$Y" "${#aliased[@]}" "$R" "${aliased[*]}"
mapfile -t CHALLENGE_TARGETS < <(printf '%s\n' "${challenge_mods[@]}" | sort -u)
printf '  %d solutions  →  challenge modules: %s\n' "$total" "${CHALLENGE_TARGETS[*]}"

built(){ find "$VERIFY/.lake/build" -path '*/Solution/*.olean' 2>/dev/null | wc -l; }

say "Building challenge statements + $total proofs (jobs=$JOBS)"
targets=("${CHALLENGE_TARGETS[@]}"); for s in "${stems[@]}"; do targets+=("Solution.$s"); done
( cd "$VERIFY" && LAKE_NUM_THREADS="$JOBS" lake build "${targets[@]}" ) >"$WORK/build.log" 2>&1 &
bpid=$!
while kill -0 "$bpid" 2>/dev/null; do bar "$(built)" "$total" "building"; sleep 0.5; done
wait "$bpid" || true
nb=$(built); bar "$nb" "$total" "built"; echo
(( nb == total )) || printf '  %s%d failed to build%s (see %s)\n' "$Y" "$((total-nb))" "$R" "$WORK/build.log"
for cm in "${CHALLENGE_TARGETS[@]}"; do
  find "$VERIFY/.lake/build" -path "*/${cm//.//}.olean" 2>/dev/null | grep -q . \
    || die "challenge module $cm failed to build (see $WORK/build.log)"
done

say "Verifying $total proofs with comparator (jobs=$JOBS)"
RES="$WORK/results"; LOGS="$WORK/logs"; rm -rf "$RES"; mkdir -p "$RES" "$LOGS"

verify_one(){
  local s=$1 log="$LOGS/$1.log" cfg="$WORK/cfg/$1.json" cmod ax
  cmod="$(cat "$WORK/cmod/$s")"
  ax="$(printf '"%s",' $PERMITTED_AXIOMS)"; ax="[${ax%,}]"
  printf '{"challenge_module":"%s","solution_module":"Solution.%s","theorem_names":["%s"],"permitted_axioms":%s,"enable_nanoda":%s}\n' \
    "$cmod" "$s" "$s" "$ax" "$NANODA_JSON" > "$cfg"
  if ( cd "$VERIFY" && "$COMP" "$cfg" ) >"$log" 2>&1 && grep -q "Your solution is okay!" "$log"; then
    echo PASS > "$RES/$s"
  else
    local why
    why=$(grep -oE "Illegal axiom detected: '[^']+'|statement do not match|not found in [a-z]+: '[^']+'|Child exited with [0-9]+" "$log" | head -1)
    echo "FAIL ${why:-see log}" > "$RES/$s"
  fi
}
NANODA_JSON=$( (( ENABLE_NANODA )) && echo true || echo false )
export -f verify_one
export VERIFY COMP WORK LOGS RES PERMITTED_AXIOMS NANODA_JSON

printf '%s\n' "${stems[@]}" | xargs -P "$JOBS" -I{} bash -c 'verify_one "$@"' _ {} &
vpid=$!
while kill -0 "$vpid" 2>/dev/null; do
  d=$(count "$RES"); p=$(grep -rl '^PASS' "$RES" 2>/dev/null | wc -l) || true
  bar "$d" "$total" "$(printf '%s✓%d %s✗%d%s verifying' "$G" "$p" "$X" "$((d-p))" "$R")"; sleep 0.5
done
wait "$vpid" || true
pass=$(grep -rl '^PASS' "$RES" 2>/dev/null | wc -l) || true; fail=$((total-pass))
bar "$(count "$RES")" "$total" "$(printf '%s✓%d %s✗%d%s done' "$G" "$pass" "$X" "$fail" "$R")"; echo

say "Summary"
if (( fail )); then
  printf '%sFailures:%s\n' "$Y" "$R"
  for s in "${stems[@]}"; do
    r=$(cat "$RES/$s" 2>/dev/null || echo "FAIL no result")
    [[ $r == PASS ]] || printf '  %s✗%s %-46s %s\n' "$X" "$R" "$s" "${r#FAIL }"
  done
  printf '\n%s✓ %d passed   ✗ %d failed%s  (of %d)   logs: %s\n' "$Y" "$pass" "$fail" "$R" "$total" "$LOGS"
  exit 1
fi
printf '%s✓ all %d proofs verified%s against official miniF2F %s\n' "$G" "$total" "$R" "${MINIF2F_COMMIT:0:9}"
printf '  each proves exactly the upstream statement, axioms ⊆ {%s}, kernel re-checked%s.\n' \
  "$PERMITTED_AXIOMS" "$( (( ENABLE_NANODA )) && echo ' (+ nanoda)')"
