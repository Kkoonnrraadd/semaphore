#!/bin/bash

# Extract Script Outputs - Simple PowerShell Output Extractor
# Usage: ./extract_script_outputs.sh [log_file]

if [[ $# -eq 1 ]]; then
    LOG_FILE="$1"
elif [[ -f "logs/run_$(date +%Y%m%d)_*.log" ]]; then
    LOG_FILE=$(ls -t logs/run_$(date +%Y%m%d)_*.log | head -1)
else
    echo "❌ No log file specified and no recent log found"
    echo "Usage: $0 [log_file]"
    exit 1
fi

if [[ ! -f "$LOG_FILE" ]]; then
    echo "❌ Log file not found: $LOG_FILE"
    exit 1
fi

echo ""
echo "🔍 PowerShell Script Outputs from: $LOG_FILE"
echo "════════════════════════════════════════════════════════════════════════════════════════"
echo ""

# Extract outputs
in_stdout=false
in_stderr=false
current_step=""
step_count=0
has_stderr=false

while IFS= read -r line; do
    # Detect step headers
    if [[ "$line" =~ "self_service_refresh : Step "[0-9]+" - " ]]; then
        current_step=$(echo "$line" | grep -o "Step [0-9]* - [^*]*" | sed 's/\*//g' | xargs)
        in_stdout=false
        in_stderr=false
        has_stderr=false
    fi
    
    # Detect start of STDOUT section
    if [[ "$line" =~ "📤 STDOUT:" ]]; then
        in_stdout=true
        in_stderr=false
        if [[ -n "$current_step" ]]; then
            ((step_count++))
            echo ""
            echo "┌─────────────────────────────────────────────────────────────────────────────────────────┐"
            echo "│ $current_step"
            echo "└─────────────────────────────────────────────────────────────────────────────────────────┘"
            echo "📤 SCRIPT OUTPUT:"
        fi
        continue
    fi
    
    # Detect start of STDERR section
    if [[ "$line" =~ "📤 STDERR:" ]]; then
        in_stdout=false
        in_stderr=true
        has_stderr=true
        echo ""
        echo "⚠️  ERRORS/WARNINGS:"
        continue
    fi
    
    # Detect end of script output section
    if [[ "$line" =~ "\[0m\[1m#" ]] || [[ "$line" =~ "🔧 Command:" ]]; then
        in_stdout=false
        in_stderr=false
        if [[ "$step_count" -gt 0 ]]; then
            echo ""
        fi
        continue
    fi
    
    # Print STDOUT content
    if [[ "$in_stdout" == "true" ]] && [[ ! "$line" =~ ^[[:space:]]*$ ]]; then
        # Clean up the line
        clean_line=$(echo "$line" | sed 's/\[0;32m//g; s/\[0m//g; s/^[[:space:]]*//g')
        if [[ -n "$clean_line" && "$clean_line" != "(no output)" ]]; then
            # Highlight errors and important messages
            if [[ "$clean_line" =~ "❌" ]] || [[ "$clean_line" =~ "Error:" ]] || [[ "$clean_line" =~ "Failed" ]]; then
                echo "  🔴 $clean_line"
            elif [[ "$clean_line" =~ "✅" ]] || [[ "$clean_line" =~ "SUCCESS" ]] || [[ "$clean_line" =~ "Completed" ]]; then
                echo "  🟢 $clean_line"
            elif [[ "$clean_line" =~ "🔍 DRY RUN" ]]; then
                echo "  🔵 $clean_line"
            else
                echo "  $clean_line"
            fi
        fi
    fi
    
    # Print STDERR content  
    if [[ "$in_stderr" == "true" ]] && [[ ! "$line" =~ ^[[:space:]]*$ ]]; then
        # Clean up the line
        clean_line=$(echo "$line" | sed 's/\[0;32m//g; s/\[0m//g; s/^[[:space:]]*//g')
        if [[ -n "$clean_line" && "$clean_line" != "(no errors)" ]]; then
            # Color code different types of errors
            if [[ "$clean_line" =~ "PermissionError" ]] || [[ "$clean_line" =~ "Permission denied" ]]; then
                echo "  🚫 $clean_line"
            elif [[ "$clean_line" =~ "InvalidOperation" ]] || [[ "$clean_line" =~ "Cannot index into a null array" ]]; then
                echo "  🔸 $clean_line"
            elif [[ "$clean_line" =~ "Traceback" ]] || [[ "$clean_line" =~ "File " ]]; then
                echo "  📄 $clean_line"
            else
                echo "  ⚠️  $clean_line"
            fi
        fi
    fi
done < "$LOG_FILE"

if [[ "$step_count" -eq 0 ]]; then
    echo "❌ No PowerShell script outputs found in log file"
    echo ""
    echo "💡 This might be because:"
    echo "   • The log file doesn't contain script execution results"
    echo "   • PowerShell scripts didn't produce output"
    echo "   • Log format has changed"
else
    echo ""
    echo "✅ Found outputs from $step_count PowerShell scripts"
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════════════════"
