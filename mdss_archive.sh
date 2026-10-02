#!/usr/bin/env bash
# mdss_archive.sh - interactively archive a folder, send it to NCI massdata (mdss),
# verify it, and (optionally) delete the original folder once verified.
# Usage: bash mdss_archive.sh      (run on a Gadi login node)

set -euo pipefail
SELF="$(readlink -f "${BASH_SOURCE[0]}")"

# ---------- helpers ----------
ask() { local r; read -r -p "$1 [${2:-}]: " r; echo "${r:-$2}"; }
yesno() {
    local r d="${2:-y}"
    read -r -p "$1 [$d/$([ "$d" = y ] && echo n || echo y)]: " r
    [[ "${r:-$d}" =~ ^[Yy] ]]
}
die()   { echo "ERROR: $*" >&2; exit 1; }
human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }
sha()   { sha256sum "$1" | cut -d' ' -f1; }

# Refuse to delete anything that looks like a top-level / home / project directory
safe_to_delete() {
    local p="$1" n
    n=$(echo "$p" | tr '/' '\n' | grep -c .)
    [ "$n" -ge 3 ] || return 1
    case "$p" in
        "$HOME"|"/scratch/$PROJ"|"/g/data/$PROJ"|"/scratch/$PROJ/$USER"|"/g/data/$PROJ/$USER") return 1 ;;
    esac
    return 0
}

# ---------- the actual work (used for "run now" and inside the copyq job) ----------
do_transfer() {
    # expects: SRC PROJ DEST COMP STAGE VERIFY DELETE_LOCAL DELETE_SRC
    command -v mdss >/dev/null || die "mdss not found. Run this on Gadi (login node or copyq)."

    case "$STAGE/" in "$SRC"/*) die "Staging dir is inside the source folder. Choose another." ;; esac

    local name ext tar_opts archive base
    name="$(basename "$SRC")"
    case "$COMP" in
        gz)   ext="tar.gz"
              if command -v pigz >/dev/null; then tar_opts=(--use-compress-program=pigz -cf)
              else tar_opts=(-czf); fi ;;
        none) ext="tar"; tar_opts=(-cf) ;;
        *)    die "Unknown compression '$COMP'" ;;
    esac
    base="${name}_$(date +%Y%m%d_%H%M%S).${ext}"
    archive="$STAGE/$base"

    # 1. create archive
    mkdir -p "$STAGE"
    echo ">> [1/5] Creating archive: $archive"
    tar "${tar_opts[@]}" "$archive" -C "$(dirname "$SRC")" "$name"
    local lsize lsha; lsize=$(stat -c %s "$archive"); lsha=$(sha "$archive")
    echo "   Size: $(human "$lsize")   sha256: $lsha"

    # 2. check archive is readable and contains every file
    echo ">> [2/5] Checking archive integrity and file count"
    tar -tf "$archive" > "$archive.list" || die "Archive is corrupted/unreadable. Nothing deleted."
    local n_tar n_src
    n_tar=$(grep -vc '/$' "$archive.list" || true)
    n_src=$(find "$SRC" ! -type d | wc -l)
    rm -f "$archive.list"
    [ "$n_tar" = "$n_src" ] || die "File count mismatch (source=$n_src, archive=$n_tar). Nothing deleted; archive kept at $archive"
    echo "   OK: $n_src files in source and archive"

    # 3. upload
    echo ">> [3/5] Uploading to massdata ($PROJ:$DEST/)"
    local path=""
    IFS='/' read -ra parts <<< "$DEST"
    for p in "${parts[@]}"; do
        [ -z "$p" ] && continue
        path="${path:+$path/}$p"
        mdss -P "$PROJ" mk "$path" 2>/dev/null || true
    done
    mdss -P "$PROJ" put "$archive" "$DEST/"
    mdss -P "$PROJ" ls -l "$DEST/$base"

    # 4. verify by downloading it back and comparing checksums
    local verified=n
    if [ "$VERIFY" = "y" ]; then
        echo ">> [4/5] Verifying: downloading copy back and comparing checksums"
        local vdir="$STAGE/.verify_$$"
        mkdir -p "$vdir"
        mdss -P "$PROJ" get "$DEST/$base" "$vdir/"
        local rsha; rsha=$(sha "$vdir/$base")
        rm -rf "$vdir"
        if [ "$rsha" = "$lsha" ]; then
            echo "   OK: checksums match"; verified=y
        else
            die "CHECKSUM MISMATCH (local=$lsha remote=$rsha). Nothing deleted. Archive kept at $archive"
        fi
    else
        echo ">> [4/5] Verification skipped"
    fi

    # 5. cleanup
    echo ">> [5/5] Cleanup"
    if [ "$DELETE_SRC" = "y" ]; then
        [ "$verified" = y ] || die "Refusing to delete source without verification."
        safe_to_delete "$SRC" || die "Refusing to delete '$SRC' (looks like a top-level directory)."
        rm -rf -- "$SRC"
        echo "   Deleted original folder: $SRC"
    fi
    if [ "$DELETE_LOCAL" = "y" ] && [ "$verified" = y ]; then
        rm -f "$archive"
        echo "   Deleted local archive."
    else
        echo "   Local archive kept: $archive"
    fi
    echo ">> Done. Data is on massdata at $PROJ:$DEST/$base"
}

# ---------- batch mode (called from the copyq job) ----------
if [ "${1:-}" = "--batch" ]; then
    : "${SRC:?}" "${PROJ:?}" "${DEST:?}" "${COMP:?}" "${STAGE:?}" \
      "${VERIFY:?}" "${DELETE_LOCAL:?}" "${DELETE_SRC:?}"
    do_transfer
    exit 0
fi

# ---------- interactive mode ----------
echo "=== Archive a folder, send it to NCI massdata, verify, and clean up ==="

SRC="$(ask "Folder to archive" "$PWD")"
SRC="$(readlink -f "${SRC/#\~/$HOME}")"
[ -d "$SRC" ] || die "'$SRC' is not a directory."
SRC_BYTES=$(du -sb "$SRC" | cut -f1)
echo "   Size: $(human "$SRC_BYTES")   Files: $(find "$SRC" ! -type d | wc -l)"

PROJ="$(ask "NCI project (for mdss)" "${PROJECT:-}")"
[ -n "$PROJ" ] || die "A project code is required."
DEST="$(ask "Destination directory on massdata (inside project)" "$USER/$(basename "$SRC")")"

echo "Compression:  1) tar.gz   2) tar only (best if data is already compressed, e.g. NetCDF with deflate)"
case "$(ask "Choose" "1")" in 1) COMP=gz ;; 2) COMP=none ;; *) die "Invalid choice." ;; esac

STAGE="$(ask "Staging directory (needs space for the archive, ~2x briefly during verification)" "/scratch/$PROJ/$USER/mdss_staging")"
case "$(readlink -f "$STAGE")/" in "$SRC"/*) die "Staging dir can't be inside the source folder." ;; esac

echo
VERIFY=y
yesno "Verify by downloading the upload back and comparing checksums? (strongly recommended)" y || VERIFY=n

DELETE_SRC=n; DELETE_LOCAL=n
if [ "$VERIFY" = y ]; then
    if yesno "Delete the ORIGINAL folder if everything verifies?" n; then
        safe_to_delete "$SRC" || die "Refusing: '$SRC' looks like a top-level directory."
        echo "   This permanently deletes: $SRC"
        read -r -p "   Type the folder name ($(basename "$SRC")) to confirm: " conf
        [ "$conf" = "$(basename "$SRC")" ] || die "Confirmation did not match. Aborting."
        DELETE_SRC=y
    fi
    yesno "Delete the local archive file after a verified upload?" y && DELETE_LOCAL=y
else
    echo "   (Original/local deletion is disabled when verification is skipped.)"
fi

echo
echo "Where should it run?"
echo "  1) copyq job - background job on the data-mover queue (recommended for > ~5 GB)"
echo "  2) right now on this login node (small folders only)"
DEF_MODE=2; [ "$SRC_BYTES" -gt $((5*1024*1024*1024)) ] && DEF_MODE=1
MODE="$(ask "Choose" "$DEF_MODE")"
[[ "$MODE" =~ ^[12]$ ]] || die "Invalid choice."

echo
echo "--- Summary ---"
echo "Source       : $SRC"
echo "Destination  : massdata ($PROJ):$DEST/"
echo "Compression  : $COMP"
echo "Staging      : $STAGE"
echo "Verify       : $VERIFY"
echo "Delete orig. : $DELETE_SRC"
echo "Delete archv.: $DELETE_LOCAL"
echo "Mode         : $([ "$MODE" = 1 ] && echo "copyq job" || echo "login node")"
yesno "Proceed?" y || { echo "Cancelled."; exit 0; }

if [ "$MODE" = 2 ]; then
    do_transfer
else
    WALL="$(ask "Walltime (HH:MM:SS)" "06:00:00")"
    MEM="$(ask "Memory" "8GB")"
    NCPUS="$(ask "CPUs (used by pigz if gzip chosen)" "1")"

    stor=""
    add_storage() {
        case "$1" in
            /scratch/*) stor+="+scratch/$(echo "$1" | cut -d/ -f3)" ;;
            /g/data/*)  stor+="+gdata/$(echo "$1" | cut -d/ -f4)" ;;
        esac
    }
    add_storage "$SRC"; add_storage "$STAGE"
    stor="massdata/$PROJ$stor"
    stor="$(echo "$stor" | tr '+' '\n' | sort -u | paste -sd+)"

    JOBSCRIPT="$(mktemp "${TMPDIR:-/tmp}/mdss_job_XXXXXX.sh")"
    {
        echo "#!/bin/bash"
        echo "#PBS -P $PROJ"
        echo "#PBS -q copyq"
        echo "#PBS -N mdss_archive"
        echo "#PBS -l walltime=$WALL"
        echo "#PBS -l ncpus=$NCPUS"
        echo "#PBS -l mem=$MEM"
        echo "#PBS -l storage=$stor"
        echo "#PBS -l wd"
        echo "#PBS -j oe"
        printf 'export SRC=%q PROJ=%q DEST=%q COMP=%q STAGE=%q VERIFY=%q DELETE_LOCAL=%q DELETE_SRC=%q\n' \
               "$SRC" "$PROJ" "$DEST" "$COMP" "$STAGE" "$VERIFY" "$DELETE_LOCAL" "$DELETE_SRC"
        printf 'bash %q --batch\n' "$SELF"
    } > "$JOBSCRIPT"

    echo "Job script written to: $JOBSCRIPT"
    qsub "$JOBSCRIPT"
    echo "Check progress with: qstat -u $USER   (log: mdss_archive.o<jobid> in $PWD)"
    [ "$DELETE_SRC" = y ] && echo "NOTE: the job will delete $SRC only after the checksum verification passes."
fi
