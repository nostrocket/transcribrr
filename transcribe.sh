#!/bin/bash

# Transcribe audio file using MLX Whisper (Apple Silicon GPU)
# Usage: ./transcribe.sh <audio_file>

# Cleanup function for graceful shutdown
cleanup() {
    echo ""
    echo ""
    echo "🛑 Interrupt detected. Cleaning up..."
    
    if [ -n "$WHISPER_PID" ] && kill -0 "$WHISPER_PID" 2>/dev/null; then
        echo "Stopping whisper process (PID: $WHISPER_PID)..."
        kill -TERM "$WHISPER_PID" 2>/dev/null
        sleep 2
        
        # Force kill if still running
        if kill -0 "$WHISPER_PID" 2>/dev/null; then
            echo "Force killing whisper process..."
            kill -9 "$WHISPER_PID" 2>/dev/null
        fi
    fi
    
    # Clean up PID file
    if [ -n "$PID_FILE" ] && [ -f "$PID_FILE" ]; then
        rm -f "$PID_FILE"
    fi
    
    echo "Cleanup complete. Partial progress saved in: $LOG_FILE"
    exit 130
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM

# Parse arguments
AUDIO_FILE=""

for arg in "$@"; do
    case $arg in
        *)
            AUDIO_FILE="$arg"
            ;;
    esac
done

if [ -z "$AUDIO_FILE" ]; then
    echo "Usage: $0 <audio_file>"
    echo "Example: $0 recording.mp3"
    exit 1
fi

if [ ! -f "$AUDIO_FILE" ]; then
    echo "Error: File '$AUDIO_FILE' not found"
    exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use the virtual environment's mlx_whisper
WHISPER_CMD="$SCRIPT_DIR/.venv/bin/mlx_whisper"

if [ ! -f "$WHISPER_CMD" ]; then
    echo "Error: mlx_whisper not found at $WHISPER_CMD"
    echo "Please install it first with: pip install mlx-whisper"
    exit 1
fi

BASENAME="${AUDIO_FILE%.*}"
AUDIO_DIR="$(dirname "$AUDIO_FILE")"
AUDIO_STEM="$(basename "${AUDIO_FILE%.*}")"

# Initialize WHISPER_PID for cleanup handler
WHISPER_PID=""

# Get audio duration using ffmpeg
echo "Analyzing audio file..."
DURATION_STR=$(ffmpeg -i "$AUDIO_FILE" 2>&1 | grep "Duration" | awk '{print $2}' | tr -d ,)
if [ -z "$DURATION_STR" ]; then
    echo "Warning: Could not determine audio duration"
    TOTAL_SECONDS=0
else
    # Convert HH:MM:SS.ms to total seconds
    IFS=: read h m s <<< "$DURATION_STR"
    TOTAL_SECONDS=$(echo "$h * 3600 + $m * 60 + $s" | bc)
    echo "Audio duration: $DURATION_STR (${TOTAL_SECONDS%.*} seconds)"
fi

# Ask user for model size
echo ""
echo "Select Whisper model:"
echo "  1) tiny       - Fastest, lowest quality (39M parameters)"
echo "  2) base       - Fast, good quality (74M parameters)"
echo "  3) small      - Balanced (244M parameters) ⭐ RECOMMENDED"
echo "  4) medium     - High quality, slower (769M parameters)"
echo "  5) large-v3   - Best quality, slowest (1550M parameters)"
echo "  6) turbo      - Near-large quality, much faster (809M parameters)"
echo "  7) custom     - Enter a custom Hugging Face model name"
echo ""
read -p "Enter choice [1-7] (default: 3): " model_choice

# Map choice to mlx-community model name
case "$model_choice" in
    1)
        MODEL_SIZE="mlx-community/whisper-tiny"
        MODEL_LABEL="tiny"
        ;;
    2)
        MODEL_SIZE="mlx-community/whisper-base-mlx"
        MODEL_LABEL="base"
        ;;
    3|"")
        MODEL_SIZE="mlx-community/whisper-small-mlx"
        MODEL_LABEL="small"
        ;;
    4)
        MODEL_SIZE="mlx-community/whisper-medium-mlx"
        MODEL_LABEL="medium"
        ;;
    5)
        MODEL_SIZE="mlx-community/whisper-large-v3-mlx"
        MODEL_LABEL="large-v3"
        ;;
    6)
        MODEL_SIZE="mlx-community/whisper-large-v3-turbo"
        MODEL_LABEL="turbo"
        ;;
    7)
        read -p "Enter Hugging Face model name (e.g. mlx-community/whisper-large-v3-turbo): " MODEL_SIZE
        MODEL_LABEL="$MODEL_SIZE"
        if [ -z "$MODEL_SIZE" ]; then
            echo "No model specified. Using 'small'."
            MODEL_SIZE="mlx-community/whisper-small-mlx"
            MODEL_LABEL="small"
        fi
        ;;
    *)
        echo "Invalid choice. Using 'small' model."
        MODEL_SIZE="mlx-community/whisper-small-mlx"
        MODEL_LABEL="small"
        ;;
esac

echo ""
echo "Using model: $MODEL_SIZE"
echo ""

OUTPUT_FILE="${BASENAME}_transcript_${MODEL_LABEL}.txt"
LOG_FILE="${BASENAME}_transcription_${MODEL_LABEL}.log"
PID_FILE="${BASENAME}_whisper_${MODEL_LABEL}.pid"

echo "Transcribing: $AUDIO_FILE"
echo "Using model: $MODEL_SIZE with GPU acceleration (Apple Silicon MLX)"

echo "Progress will be saved to: $LOG_FILE"
echo "Transcript will be saved to: $OUTPUT_FILE"
echo ""

# Run mlx_whisper: verbose output to log for progress tracking, txt output file is clean (no timestamps)
PYTHONUNBUFFERED=1 "$WHISPER_CMD" "$AUDIO_FILE" --model "$MODEL_SIZE" --output-format txt --verbose True --language en --condition-on-previous-text False --output-dir "$AUDIO_DIR" > "$LOG_FILE" 2>&1 &
WHISPER_PID=$!
echo "$WHISPER_PID" > "$PID_FILE"

echo "Whisper process started (PID: $WHISPER_PID)"
echo "Full output: $LOG_FILE"
echo ""
echo "========================================"
echo ""

# Monitor progress
START_TIME=$(date +%s)
LAST_LOG_SIZE=0
STUCK_COUNTER=0

while kill -0 "$WHISPER_PID" 2>/dev/null; do
    # Check current log size to detect if process is stuck
    CURRENT_LOG_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    
    # Extract latest timestamp from log (format: [HH:MM:SS.mmm --> HH:MM:SS.mmm])
    LATEST_TIMESTAMP=$(grep -o '\[.*-->' "$LOG_FILE" 2>/dev/null | tail -1 | sed 's/\[//' | sed 's/-->//' | awk '{print $1}')
    
    # Check for errors in log
    if grep -q "Error\|Exception\|Traceback\|ValueError" "$LOG_FILE" 2>/dev/null; then
        echo ""
        echo ""
        echo "⚠️  ERROR DETECTED IN LOG FILE:"
        echo "========================================"
        tail -50 "$LOG_FILE"
        echo "========================================"
        break
    fi
    
    # Check if log file is growing (process is making progress)
    if [ "$CURRENT_LOG_SIZE" -eq "$LAST_LOG_SIZE" ]; then
        STUCK_COUNTER=$((STUCK_COUNTER + 1))
    else
        STUCK_COUNTER=0
    fi
    LAST_LOG_SIZE=$CURRENT_LOG_SIZE
    
    # If stuck for too long (60 seconds = 20 iterations * 3 seconds), warn user
    if [ "$STUCK_COUNTER" -gt 20 ]; then
        echo ""
        echo "⚠️  WARNING: Process appears stuck (no output for 60+ seconds)"
        echo "Process is still running (PID: $WHISPER_PID). Waiting..."
        STUCK_COUNTER=0  # Reset counter to avoid spam
    fi
    
    if [ -n "$LATEST_TIMESTAMP" ]; then
        # Convert timestamp to seconds (handles both MM:SS.mmm and HH:MM:SS.mmm formats)
        COLON_COUNT=$(echo "$LATEST_TIMESTAMP" | tr -cd ':' | wc -c | tr -d ' ')
        if [ "$COLON_COUNT" -eq 1 ]; then
            # MM:SS.mmm format
            IFS=: read m s <<< "$LATEST_TIMESTAMP"
            CURRENT_SECONDS=$(echo "$m * 60 + $s" | bc 2>/dev/null)
        else
            # HH:MM:SS.mmm format
            IFS=: read h m s <<< "$LATEST_TIMESTAMP"
            CURRENT_SECONDS=$(echo "$h * 3600 + $m * 60 + $s" | bc 2>/dev/null)
        fi
        
        if [ -n "$CURRENT_SECONDS" ] && [ "$TOTAL_SECONDS" != "0" ]; then
            # Calculate progress percentage
            PROGRESS=$(echo "scale=1; ($CURRENT_SECONDS / $TOTAL_SECONDS) * 100" | bc)
            
            # Calculate elapsed time
            NOW=$(date +%s)
            ELAPSED=$((NOW - START_TIME))
            
            # Calculate ETA if progress has advanced
            if (( $(echo "$CURRENT_SECONDS > 0" | bc -l) )); then
                PROCESSING_RATE=$(echo "scale=4; $CURRENT_SECONDS / $ELAPSED" | bc)
                REMAINING_SECONDS=$(echo "($TOTAL_SECONDS - $CURRENT_SECONDS) / $PROCESSING_RATE" | bc 2>/dev/null)
                
                if [ -n "$REMAINING_SECONDS" ] && [ "$REMAINING_SECONDS" != "0" ]; then
                    ETA_H=$((REMAINING_SECONDS / 3600))
                    ETA_M=$(( (REMAINING_SECONDS % 3600) / 60 ))
                    printf "\r  Progress: %s%% | %s / %s | Rate: %sx | ETA: %dh %dm   " "$PROGRESS" "$LATEST_TIMESTAMP" "$DURATION_STR" "$PROCESSING_RATE" "$ETA_H" "$ETA_M"
                fi
            fi
        fi
    fi
    
    sleep 3
done

echo ""
echo ""

# Wait for the process to complete
wait "$WHISPER_PID"
EXIT_CODE=$?

# Clean up PID file
rm -f "$PID_FILE"

# Rename the default output to our preferred filename and prepend model info
# mlx_whisper writes to <output-dir>/<audio_stem>.txt
WHISPER_OUTPUT="${AUDIO_DIR}/${AUDIO_STEM}.txt"
if [ -f "$WHISPER_OUTPUT" ]; then
    {
        echo "Model: $MODEL_SIZE"
        echo "Source: $(basename "$AUDIO_FILE")"
        echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        cat "$WHISPER_OUTPUT"
    } > "$OUTPUT_FILE"
    rm "$WHISPER_OUTPUT"
fi

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "Done!"
    echo "Transcript: $OUTPUT_FILE"
    echo "Progress log: $LOG_FILE"
else
    echo ""
    echo "❌ Whisper exited with error code: $EXIT_CODE"
    echo ""
    echo "Last 50 lines of log file:"
    echo "========================================"
    tail -50 "$LOG_FILE"
    echo "========================================"
    echo ""
    echo "Full log file: $LOG_FILE"
    
    exit $EXIT_CODE
fi
