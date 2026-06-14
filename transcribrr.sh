#!/bin/bash

set -euo pipefail

# transcribrr.sh — End-to-end audio pipeline orchestrator
# Drives transcribe.sh -> cleanup-transcript.sh -> summarize-transcript.sh unattended.
# Accepts a YouTube URL (downloads audio via yt-dlp) or a local MP3 path.
# Usage: ./transcribrr.sh <youtube-url|audio.mp3> [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults (per D-08) ──────────────────────────────────────────────────────

WHISPER_MODEL="small"
CLEANUP_MODEL="llama3.1-8b-4bit"
SUMMARY_MODEL="Qwen2.5-32B-4bit"
SUMMARY_STYLE="blog"
NO_CLEANUP=false
NO_INSTALL=false
MP3_FILE=""
INPUT_ARG=""
IS_URL=false
URL=""

# ── ERR trap — names the failing stage ───────────────────────────────────────

CURRENT_STAGE="preflight"
trap 'echo "Error: transcribrr.sh failed during stage: $CURRENT_STAGE" >&2' ERR

# ── Help ─────────────────────────────────────────────────────────────────────

print_help() {
    cat << 'EOF'
Usage: transcribrr.sh <youtube-url|audio.mp3> [options]

  Transcribes, cleans, and summarizes audio using local MLX models.
  Give it a YouTube URL to download and process, or a local MP3 to process directly.
  Runs transcribe.sh -> cleanup-transcript.sh -> summarize-transcript.sh
  fully unattended with zero interactive prompts.

  For YouTube URLs, video metadata (title, channel, duration, upload date) is
  captured and included in the output markdown header. Some fields may show
  "NA" for private or age-gated videos.

Arguments:
  <youtube-url|audio.mp3>  YouTube URL to download, or path to a local MP3
                           (or any ffmpeg-readable audio) file

Options:
  --whisper-model <label|hf-id>
                          Whisper model for transcription.
                          Labels: tiny, base, small, medium, large-v3, turbo
                          Or a raw Hugging Face model ID (must contain '/')
                          Default: small

  --cleanup-model <label|hf-id>
                          LLM for transcript cleanup.
                          Labels: llama3.2-1b-4bit, llama3.2-3b-4bit,
                                  llama3.1-8b-4bit, llama3.1-8b-8bit
                          Or a raw Hugging Face model ID
                          Default: llama3.1-8b-4bit

  --no-cleanup            Skip the transcript cleanup stage and feed the raw
                          transcript directly into summarization.

  --summary-model <label|hf-id>
                          LLM for summarization.
                          Labels: Qwen2.5-7B-4bit, Qwen2.5-14B-4bit,
                                  Qwen2.5-32B-4bit, Qwen2.5-32B-8bit
                          Or a raw Hugging Face model ID
                          Default: Qwen2.5-32B-4bit

  --summary-style <style>
                          Summary output style.
                          Styles: executive, detailed, bullets, chapters, blog
                          Default: blog

  --no-install            Do not auto-install missing dependencies; fail with an
                          install hint instead (default: auto-install via Homebrew).

  --help, -h              Show this help message and exit

Examples:
  transcribrr.sh https://www.youtube.com/watch?v=dQw4w9WgXcQ
  transcribrr.sh https://youtu.be/dQw4w9WgXcQ --summary-style detailed
  transcribrr.sh https://www.youtube.com/watch?v=dQw4w9WgXcQ --whisper-model turbo --no-cleanup
  transcribrr.sh talk.mp3
  transcribrr.sh talk.mp3 --whisper-model turbo --summary-style detailed
  transcribrr.sh talk.mp3 --no-cleanup --summary-model Qwen2.5-7B-4bit
  transcribrr.sh talk.mp3 --whisper-model mlx-community/whisper-large-v3-turbo
  transcribrr.sh talk.mp3 --cleanup-model llama3.2-3b-4bit --summary-style bullets
EOF
}

# ── Flag parsing ─────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        --whisper-model)
            WHISPER_MODEL="$2"
            shift 2
            ;;
        --cleanup-model)
            CLEANUP_MODEL="$2"
            shift 2
            ;;
        --summary-model)
            SUMMARY_MODEL="$2"
            shift 2
            ;;
        --summary-style)
            SUMMARY_STYLE="$2"
            shift 2
            ;;
        --no-cleanup)
            NO_CLEANUP=true
            shift
            ;;
        --no-install)
            NO_INSTALL=true
            shift
            ;;
        --help|-h)
            print_help
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1
            ;;
        *)
            INPUT_ARG="$1"
            shift
            ;;
    esac
done

# ── URL vs local input detection (D-01) ──────────────────────────────────────
# Must run before preflight_check so yt-dlp check is URL-conditional.

if [[ "$INPUT_ARG" =~ ^https?:// ]] || [[ "$INPUT_ARG" =~ youtu\.?be ]]; then
    IS_URL=true
    URL="$INPUT_ARG"
else
    MP3_FILE="$INPUT_ARG"
    # Derive SAFE_TITLE from the local input basename so the downstream assemble
    # stage has SAFE_TITLE defined on both input paths (URL path sets it during
    # the metadata stage; local path sets it here).
    # Strip ANY extension, not just ".mp3" — the help text advertises any
    # ffmpeg-readable audio, so "talk.wav" must not leak ".wav" into the title
    # or the final filename (WR-04).
    SAFE_TITLE=$(basename "$MP3_FILE")
    SAFE_TITLE="${SAFE_TITLE%.*}"
    SAFE_TITLE=$(printf '%s' "$SAFE_TITLE" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
    # Fall back to a non-empty default if the basename sanitizes to "" (e.g. a
    # file literally named ".mp3") so we never write a hidden ".md" (WR-01).
    if [ -z "$SAFE_TITLE" ]; then
        SAFE_TITLE="transcribrr_output"
    fi
fi

# ── ensure_dep: auto-install or hint for a missing dependency ────────────────
# Usage: ensure_dep <command> <brew-formula>
# Returns 0 if the command is available (after install if needed), 1 on failure.
# Respects NO_INSTALL: when true, never attempts brew; just emits the hint.

ensure_dep() {
    local cmd="$1"
    local formula="$2"

    if command -v "$cmd" &>/dev/null; then
        return 0
    fi

    if [ "$NO_INSTALL" = true ]; then
        echo "Error: $cmd not found on PATH. Install with: brew install $formula (or drop --no-install to auto-install)." >&2
        return 1
    fi

    # Auto-install path
    if ! command -v brew &>/dev/null; then
        echo "Error: $cmd not found and Homebrew (brew) is not installed; cannot auto-install. Install Homebrew (https://brew.sh) or install $cmd manually." >&2
        return 1
    fi

    echo "Installing missing dependency: $cmd (brew install $formula)..." >&2
    brew install "$formula"

    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: auto-install of $cmd via 'brew install $formula' did not produce a working '$cmd' on PATH." >&2
        return 1
    fi

    echo "Installed $cmd." >&2
    return 0
}

# ── Preflight check (D-10, ROB-01) ───────────────────────────────────────────
# Accumulates ALL failures before aborting so the user can fix everything at once.

preflight_check() {
    local errors=0

    # Validate input (URL or local file)
    if [ "$IS_URL" = true ]; then
        if [ -z "$URL" ]; then
            echo "Error: URL argument is empty." >&2
            errors=$((errors + 1))
        fi
    else
        if [ -z "$MP3_FILE" ] || [ ! -f "$MP3_FILE" ]; then
            echo "Error: Input file not found: ${MP3_FILE:-<not specified>}" >&2
            errors=$((errors + 1))
        fi
    fi

    # Validate each required sub-script exists and is executable
    for script in transcribe.sh cleanup-transcript.sh summarize-transcript.sh; do
        local path="$SCRIPT_DIR/$script"
        if [ ! -f "$path" ]; then
            echo "Error: Required script not found: $path" >&2
            errors=$((errors + 1))
        elif [ ! -x "$path" ]; then
            echo "Error: Script is not executable: $path" >&2
            errors=$((errors + 1))
        fi
    done

    # Validate ffmpeg is available (transcribe.sh uses it for duration); auto-install if needed
    ensure_dep ffmpeg ffmpeg || errors=$((errors + 1))

    # Validate yt-dlp is available when processing a URL (DL-02, ROB-01); auto-install if needed
    if [ "$IS_URL" = true ]; then
        ensure_dep yt-dlp yt-dlp || errors=$((errors + 1))
    fi

    if [ "$errors" -gt 0 ]; then
        echo "Aborting: $errors preflight check(s) failed." >&2
        exit 1
    fi
}

# ── Stage progress banner (CLI-03) ───────────────────────────────────────────

stage_banner() {
    local msg="$1"
    echo ""
    echo "=========================================="
    echo "  $msg"
    echo "=========================================="
    echo ""
}

preflight_check

# ── URL-only stages: url-check, metadata, download ───────────────────────────

if [ "$IS_URL" = true ]; then

    # -- url-check: reject playlist URLs before any network call (ROB-02) -----

    CURRENT_STAGE="url-check"
    # Assign pattern to variable — bash requires this to avoid ERE character-class
    # tokenization errors when the pattern contains & inside [[ =~ ]] (bash bug).
    _PLAYLIST_PATTERN="[?&]list="
    if [[ "$URL" =~ $_PLAYLIST_PATTERN ]] || [[ "$URL" =~ youtube\.com/playlist ]]; then
        echo "Error: Playlist URLs are not supported in v1." >&2
        echo "  To download a single video, remove the '&list=...' parameter from the URL." >&2
        exit 1
    fi

    # -- metadata: capture title, channel, URL, duration, upload date, id -----

    CURRENT_STAGE="metadata"
    stage_banner "Stage 1/5: Fetching metadata and downloading audio (yt-dlp)..."

    # Expected number of --print fields below. Keep in lockstep with the
    # --print list and the field assignments (IN-03).
    EXPECTED_META_FIELDS=6

    # bash 3.2 (stock macOS /bin/bash) has no mapfile/readarray, so populate the
    # array with a portable read loop instead (CR-01). yt-dlp's stderr is
    # captured to a temp file so actionable errors (bot-detection, age-gating,
    # geo-block, stale yt-dlp) can be surfaced on failure rather than swallowed
    # by 2>/dev/null (WR-03).
    META_ERR=$(mktemp)
    META=()
    while IFS= read -r line; do
        META+=("$line")
    done < <(yt-dlp \
        --simulate \
        --no-playlist \
        --print "%(title)s" \
        --print "%(channel|uploader)s" \
        --print "%(webpage_url)s" \
        --print "%(duration_string)s" \
        --print "%(upload_date)s" \
        --print "%(id)s" \
        "$URL" 2>"$META_ERR")

    # Exact field-count guard (CR-02): yt-dlp emits one line per field, but a
    # title or channel containing a newline splits across slots and silently
    # shifts every later field down (corrupting VIDEO_ID, channel, and the
    # output paths). A "-lt 6" lower-bound check passes such misaligned input;
    # an exact "-ne 6" check turns the silent corruption into a loud failure.
    # set -e is not inherited inside process substitution, so this guard is the
    # only thing that catches a metadata failure (SC2311).
    if [ "${#META[@]}" -ne "$EXPECTED_META_FIELDS" ]; then
        echo "Error: metadata stage returned ${#META[@]} field(s), expected exactly $EXPECTED_META_FIELDS." >&2
        echo "  A video title or channel name containing a newline can cause this." >&2
        if [ -s "$META_ERR" ]; then
            echo "  yt-dlp reported:" >&2
            sed 's/^/    /' "$META_ERR" >&2
        fi
        rm -f "$META_ERR"
        exit 1
    fi
    rm -f "$META_ERR"

    VIDEO_TITLE="${META[0]}"
    VIDEO_CHANNEL="${META[1]}"
    VIDEO_URL="${META[2]}"
    VIDEO_DURATION="${META[3]}"
    VIDEO_UPLOAD_DATE_RAW="${META[4]}"
    VIDEO_ID="${META[5]}"

    # Reformat upload date from YYYYMMDD to YYYY-MM-DD (NA passes through unchanged)
    if [[ "$VIDEO_UPLOAD_DATE_RAW" =~ ^[0-9]{8}$ ]]; then
        VIDEO_UPLOAD_DATE=$(echo "$VIDEO_UPLOAD_DATE_RAW" | \
            sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3/')
    else
        VIDEO_UPLOAD_DATE="$VIDEO_UPLOAD_DATE_RAW"
    fi

    # Sanitize title for safe filesystem use (Security: removes / and shell-meta chars)
    SAFE_TITLE=$(echo "$VIDEO_TITLE" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
    # An all-symbol title (e.g. "???///") sanitizes to "" which would yield a
    # hidden ".md" final file and a "_<id>" working dir (WR-01). Fall back to the
    # video id so the output is always visible and non-colliding.
    if [ -z "$SAFE_TITLE" ]; then
        SAFE_TITLE="${VIDEO_ID:-transcribrr_output}"
    fi
    # Append video ID for collision-free working directory naming (Pitfall 5)
    WORK_DIR="$(pwd)/${SAFE_TITLE}_${VIDEO_ID}"

    # -- download: extract MP3 audio into per-video working directory ----------

    CURRENT_STAGE="download"
    stage_banner "Stage 1/5: Downloading audio (yt-dlp)..."

    mkdir -p "$WORK_DIR"

    MP3_FILE=$(yt-dlp \
        -x --audio-format mp3 \
        --no-playlist \
        -o "${WORK_DIR}/%(title)s.%(ext)s" \
        --print "after_move:filepath" \
        "$URL")

    # Guard: after_move:filepath can emit stale intermediate path (Pitfall 1)
    if [ -z "$MP3_FILE" ] || [ ! -f "$MP3_FILE" ]; then
        MP3_FILE=$(find "$WORK_DIR" -name "*.mp3" | sort | tail -1)
        if [ -z "$MP3_FILE" ] || [ ! -f "$MP3_FILE" ]; then
            echo "Error: download stage did not produce a valid MP3 file in $WORK_DIR" >&2
            exit 1
        fi
    fi

fi

# ── Stage 1 (local) / Stage 3 (URL): Transcribe (TR-03) ─────────────────────

CURRENT_STAGE="transcribe"
if [ "$IS_URL" = true ]; then
    stage_banner "Stage 2/5: Transcribing (whisper model: $WHISPER_MODEL)"
else
    stage_banner "Stage 1/3: Transcribing (whisper model: $WHISPER_MODEL)"
fi

STAGE_OUT=$("$SCRIPT_DIR/transcribe.sh" "$MP3_FILE" --model "$WHISPER_MODEL" \
    | tee /dev/stderr \
    | { grep "^OUTPUT_FILE=" || true; })
TRANSCRIPT_FILE="${STAGE_OUT#OUTPUT_FILE=}"

if [ -z "$TRANSCRIPT_FILE" ] || [ ! -f "$TRANSCRIPT_FILE" ]; then
    echo "Error: transcribe stage did not produce a valid output file." >&2
    exit 1
fi

# ── Stage 2 (local) / Stage 4 (URL): Cleanup (CL-03, D-09) ──────────────────

CLEANED_FILE=""
if [ "$NO_CLEANUP" = false ]; then
    CURRENT_STAGE="cleanup"
    if [ "$IS_URL" = true ]; then
        stage_banner "Stage 3/5: Cleaning transcript (model: $CLEANUP_MODEL)"
    else
        stage_banner "Stage 2/3: Cleaning transcript (model: $CLEANUP_MODEL)"
    fi

    STAGE_OUT=$("$SCRIPT_DIR/cleanup-transcript.sh" "$TRANSCRIPT_FILE" --model "$CLEANUP_MODEL" \
        | tee /dev/stderr \
        | { grep "^OUTPUT_FILE=" || true; })
    CLEANED_FILE="${STAGE_OUT#OUTPUT_FILE=}"

    if [ -z "$CLEANED_FILE" ] || [ ! -f "$CLEANED_FILE" ]; then
        echo "Error: cleanup stage did not produce a valid output file." >&2
        exit 1
    fi

    SUMMARIZE_INPUT="$CLEANED_FILE"
else
    echo "Skipping cleanup stage (--no-cleanup specified)."
    SUMMARIZE_INPUT="$TRANSCRIPT_FILE"
fi

# ── Stage 3 (local) / Stage 5 (URL): Summarize (SUM-03) ─────────────────────

CURRENT_STAGE="summarize"
if [ "$IS_URL" = true ]; then
    stage_banner "Stage 4/5: Summarizing (model: $SUMMARY_MODEL, style: $SUMMARY_STYLE)"
else
    stage_banner "Stage 3/3: Summarizing (model: $SUMMARY_MODEL, style: $SUMMARY_STYLE)"
fi

STAGE_OUT=$("$SCRIPT_DIR/summarize-transcript.sh" "$SUMMARIZE_INPUT" \
    --model "$SUMMARY_MODEL" \
    --style "$SUMMARY_STYLE" \
    | tee /dev/stderr \
    | { grep "^OUTPUT_FILE=" || true; })
SUMMARY_FILE="${STAGE_OUT#OUTPUT_FILE=}"

if [ -z "$SUMMARY_FILE" ] || [ ! -f "$SUMMARY_FILE" ]; then
    echo "Error: summarize stage did not produce a valid output file." >&2
    exit 1
fi

# ── Stage 5/5 (URL) / final (local): Assemble markdown (OUT-01, OUT-02, OUT-03) ──

CURRENT_STAGE="assemble"
if [ "$IS_URL" = true ]; then
    stage_banner "Stage 5/5: Assembling final markdown..."
else
    stage_banner "Assembling final markdown..."
fi

# For local-MP3 input, VIDEO_* vars are not set — default them safely (set -u).
# For URL input, these are already set from the metadata stage; defaults are never reached.
_VID_TITLE="${VIDEO_TITLE:-$SAFE_TITLE}"
_VID_CHANNEL="${VIDEO_CHANNEL:-NA}"
_VID_URL="${VIDEO_URL:-NA}"
_VID_DURATION="${VIDEO_DURATION:-NA}"

# Reformat upload date for URL path (already set from metadata stage).
# For local path, VIDEO_UPLOAD_DATE_RAW is unset; default to NA.
_VID_DATE_RAW="${VIDEO_UPLOAD_DATE_RAW:-NA}"
if [[ "$_VID_DATE_RAW" =~ ^[0-9]{8}$ ]]; then
    _VID_DATE=$(echo "$_VID_DATE_RAW" | \
        sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3/')
else
    _VID_DATE="$_VID_DATE_RAW"
fi
# For URL path, VIDEO_UPLOAD_DATE is already set by the metadata stage (may be reformatted
# or NA-passthrough); prefer it if available so we don't re-reformat an already reformatted date.
_VID_UPLOAD_DATE="${VIDEO_UPLOAD_DATE:-$_VID_DATE}"

# Final markdown path: SAFE_TITLE is set by Plan 01 on both URL and local paths.
FINAL_MD_PATH="$(pwd)/${SAFE_TITLE}.md"
# Refuse to clobber an existing result (WR-05): two videos whose titles sanitize
# to the same SAFE_TITLE — or re-processing the same local file — would otherwise
# silently overwrite a prior unattended run with no warning. Fail loudly instead
# so no data is lost (stays within the predictable-path decision in CONTEXT.md).
if [ -e "$FINAL_MD_PATH" ]; then
    echo "Error: $FINAL_MD_PATH already exists; refusing to overwrite." >&2
    echo "  Move or rename the existing file, then re-run." >&2
    exit 1
fi
TEMP_MD=$(mktemp)
# EXIT trap removes the temp file on premature exit; cleared after successful mv (ROB-03).
trap 'rm -f "$TEMP_MD"' EXIT

# Select transcript variant: cleaned when cleanup ran, raw when --no-cleanup (CONTEXT.md).
if [ "$NO_CLEANUP" = false ] && [ -n "${CLEANED_FILE:-}" ] && [ -f "$CLEANED_FILE" ]; then
    EMBED_TRANSCRIPT="$CLEANED_FILE"
else
    EMBED_TRANSCRIPT="$TRANSCRIPT_FILE"
fi

# Write document into temp file in order: title, metadata block, summary, transcript (OUT-01).
# Use printf (not heredoc) so variable values are not re-expanded (Security Domain).
{
    printf "# %s\n\n" "$_VID_TITLE"
    printf -- "- **Title:** %s\n" "$_VID_TITLE"
    printf -- "- **Channel:** %s\n" "$_VID_CHANNEL"
    printf -- "- **Source URL:** %s\n" "$_VID_URL"
    printf -- "- **Duration:** %s\n" "$_VID_DURATION"
    printf -- "- **Upload date:** %s\n" "$_VID_UPLOAD_DATE"
    if [ "$NO_CLEANUP" = false ]; then
        printf -- "- **Models used:** whisper=%s, cleanup=%s, summary=%s (%s)\n\n" \
            "$WHISPER_MODEL" "$CLEANUP_MODEL" "$SUMMARY_MODEL" "$SUMMARY_STYLE"
    else
        printf -- "- **Models used:** whisper=%s, cleanup=skipped, summary=%s (%s)\n\n" \
            "$WHISPER_MODEL" "$SUMMARY_MODEL" "$SUMMARY_STYLE"
    fi
    printf "## Summary\n\n"
    # Strip summarize-transcript.sh's own header (# heading + metadata block + --- divider)
    # so the assembled doc has a single top-level title (Pitfall 6).
    sed '1,/^---/d' "$SUMMARY_FILE"
    printf "\n## Transcript\n\n"
    cat "$EMBED_TRANSCRIPT"
} > "$TEMP_MD"

# Atomic move: FINAL_MD_PATH exists only after full success (T-02-05 / ROB-03).
mv "$TEMP_MD" "$FINAL_MD_PATH"
trap - EXIT  # temp file safely moved; remove cleanup trap

echo ""
echo "=========================================="
echo "  Pipeline complete!"
echo "=========================================="
echo "Markdown: $FINAL_MD_PATH"
