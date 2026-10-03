#!/usr/bin/env bash
# Extract the Windows-side firmware payload for the ASUS Zenbook A16 (UX3607OA,
# Snapdragon X2 Elite / "Glymur", SoC id 8480) out of the Windows DriverStore on
# the other OS, so the installed Linux system can use the vendor blobs.
#
# Run on the Windows/WSL side (the A16 is the same machine; nothing here reads
# the Linux install). Output is a directory tree plus MANIFEST.tsv.
#
#   OUT=firmware/from-windows-2026-09-16 ./scripts/extract-windows-a16-firmware.sh
#   DRY_RUN=1 OUT=/tmp/x ./scripts/extract-windows-a16-firmware.sh   # report only
#
# What is in scope: every payload file in the Qualcomm driver packages whose name
# carries the SoC id (8480). What is not: driver code (.sys/.inf/.cat/.dll/.exe),
# Windows AI models (.pmd), and the Hexagon userspace module trees (ADSP/*.so,
# CDSP/*.so, HTP/*.so) -- the latter are Windows-side userspace libraries, not
# loadable firmware images; see EXCLUDE_EXT below and the README.
set -euo pipefail

SRC=${SRC:-/mnt/c/Windows/System32/DriverStore/FileRepository}
OUT=${OUT:-}
DRY_RUN=${DRY_RUN:-0}
INCLUDE_DSP_MODULES=${INCLUDE_DSP_MODULES:-0}

if [ -z "$OUT" ]; then
    echo "usage: OUT=<dir> $0   (env: SRC, DRY_RUN, INCLUDE_DSP_MODULES)" >&2
    exit 2
fi

# Driver code, Windows AI models, test images, packaging metadata.
EXCLUDE_EXT='sys inf cat pnf dll exe pmd ppkg sig yuv nv12 lst ini cpl ocx pdb lib obj'
[ "$INCLUDE_DSP_MODULES" = 1 ] || EXCLUDE_EXT="$EXCLUDE_EXT so"

is_excluded() {  # $1 = filename
    local f=${1,,} ext
    case $f in *'.so.') return 0 ;; *.so.*) return 0 ;; esac   # lib*.so.1 style
    ext=${f##*.}
    [ "$ext" = "$f" ] && return 1                      # no extension -> keep
    for e in $EXCLUDE_EXT; do [ "$ext" = "$e" ] && return 0; done
    return 1
}

group_of() {  # $1 = driver package directory name
    case $1 in
        qcwlancol*|qcwlanhmt*)                  echo wlan ;;
        qcbluetooth*|qcbtacx*)                  echo bluetooth ;;
        qcsubsys_ext_adsp*|qcacsp*|qcadcm*|qcadc*|qcasd*|qcascd*|qcaucd*|qcabd*|qcadx*|qcadsprpc*) echo adsp ;;
        qcsubsys_ext_cdsp*|qcnspmcdm*)          echo cdsp ;;
        qcdx*|qceva*)                           echo gpu-video ;;
        qctreeextqcom*|qcdpps*)                 echo display-hdcp ;;
        qccam*)                                 echo camera ;;
        qcsensor*)                              echo sensors ;;
        *)                                      echo platform ;;
    esac
}

mapfile -t PKGS < <(find "$SRC" -maxdepth 1 -mindepth 1 -type d \
      \( -name 'qc*8480*' -o -name 'halextqc*' -o -name 'dax3_ext_qc*' -o -name 'plutonqc*' \) \
      -printf '%f\n' | sort)
[ "${#PKGS[@]}" -gt 0 ] || { echo "no Qualcomm driver packages under $SRC" >&2; exit 1; }

MANIFEST=$OUT/MANIFEST.tsv
[ "$DRY_RUN" = 1 ] || { mkdir -p "$OUT"; printf 'group\tpackage\tfile\tbytes\tsha256\tstatus\tsource\n' > "$MANIFEST"; }

# Payload already committed elsewhere in this repo (e.g. the ADSP/CDSP images
# under firmware/qcom/glymur/ASUSTeK/UX3607OA/) is recorded, not copied twice.
REPO_FW=${REPO_FW:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/firmware}
declare -A IN_REPO
if [ -d "$REPO_FW" ]; then
    repo_abs=$(realpath -m "$REPO_FW"); out_abs=$(realpath -m "$OUT")
    while read -r h p; do
        abs="$repo_abs/${p#./}"
        case $abs in "$out_abs"/*) continue ;; esac   # never match our own output
        IN_REPO[$h]="${p#./}"
    done < <(cd "$REPO_FW" && find . -type f -print0 | xargs -0 sha256sum 2>/dev/null)
fi

declare -A SEEN_HASH          # sha256 -> first copied relative path
GROUPS=()                     # group names, in first-seen order
n_files=0 n_copied=0 n_dup=0 n_repo=0 n_bytes=0 n_kept_bytes=0

for pkg in "${PKGS[@]}"; do
    group=$(group_of "$pkg")
    while IFS= read -r f; do
        rel=${f#"$SRC/"}                       # <package>/<subdir>/<file>
        name=$(basename "$f")
        is_excluded "$name" && continue
        size=$(stat -c%s "$f")
        n_files=$((n_files+1)); n_bytes=$((n_bytes+size))
        h=$(sha256sum "$f" | cut -d' ' -f1)

        if [ -n "${IN_REPO[$h]:-}" ]; then
            n_repo=$((n_repo+1))
            [ "$DRY_RUN" = 1 ] || printf '%s\t%s\t%s\t%s\t%s\talready-in-repo firmware/%s\t%s\n' \
                "$group" "$pkg" "$name" "$size" "$h" "${IN_REPO[$h]}" "$f" >> "$MANIFEST"
            continue
        fi

        if [ -n "${SEEN_HASH[$h]:-}" ]; then
            n_dup=$((n_dup+1))
            [ "$DRY_RUN" = 1 ] || printf '%s\t%s\t%s\t%s\t%s\tduplicate-of %s\t%s\n' \
                "$group" "$pkg" "$name" "$size" "$h" "${SEEN_HASH[$h]}" "$f" >> "$MANIFEST"
            continue
        fi

        dest=$group/$rel
        n_copied=$((n_copied+1)); n_kept_bytes=$((n_kept_bytes+size))
        case " ${GROUPS[*]-} " in *" $group "*) ;; *) GROUPS+=("$group");; esac
        SEEN_HASH[$h]=$dest
        if [ "$DRY_RUN" = 1 ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$group" "$rel" "$size" "$h" "$dest" "$f"
        else
            mkdir -p "$OUT/$group/$pkg"
            cp -p "$f" "$OUT/$group/$pkg/$name"
            printf '%s\t%s\t%s\t%s\t%s\tcopied\t%s\n' "$group" "$pkg" "$name" "$size" "$h" "$f" >> "$MANIFEST"
        fi
    done < <(find "$SRC/$pkg" -type f | sort)
done

if [ "$DRY_RUN" = 1 ]; then
    echo "--- dry run: $n_files candidate files, $n_copied unique, $n_dup duplicate"
    printf 'raw %.1f MiB, after dedupe %.1f MiB\n' \
        "$(awk -v b="$n_bytes" 'BEGIN{print b/1048576}')" "$(awk -v b="$n_kept_bytes" 'BEGIN{print b/1048576}')"
    exit 0
fi

# Manifest must not hash itself (a self-hash ships a hash of an empty file and
# makes the target's `sha256sum -c` print FAILED).
( cd "$OUT" && find . -type f ! -name 'sha256sums.txt*' ! -name 'MANIFEST.tsv' -print0 \
    | sort -z | xargs -0 sha256sum > /tmp/.a16fw-sums.$$ && mv /tmp/.a16fw-sums.$$ sha256sums.txt )

printf 'candidate files %d -> %d copied (%d duplicates, %d already in repo)\n' "$n_files" "$n_copied" "$n_dup" "$n_repo"
printf 'on disk: %s\n' "$(du -sh "$OUT" | cut -f1)"
printf 'verify:  ( cd %s && sha256sum -c sha256sums.txt )\n' "$OUT"
