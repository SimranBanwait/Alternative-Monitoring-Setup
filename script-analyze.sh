#!/bin/bash
set -euo pipefail

# =====================================================================
# Analysis Script - Build Stage
# This script analyzes what alarms need to be created or deleted
# Outputs: plan.json (list of actions to take)
# =====================================================================

AWS_REGION="${AWS_REGION:-us-east-1}"
ALARM_SUFFIX="-cloudwatch-alarm"
ALARM_THRESHOLD="${ALARM_THRESHOLD:-5}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# =====================================================================
# Helper Functions
# =====================================================================

extract_queue_name() {
    echo "$1" | awk -F'/' '{print $NF}'
}

is_dlq() {
    [[ "$1" =~ -dlq$ || "$1" =~ -dead-letter$ || "$1" =~ _dlq$ ]]
}

get_threshold() {
    if is_dlq "$1"; then echo "1"; else echo "$ALARM_THRESHOLD"; fi
}

# =====================================================================
# Fetch Data
# =====================================================================

get_sqs_queues() {
    aws sqs list-queues \
        --region "$AWS_REGION" \
        --query 'QueueUrls' \
        --output text 2>/dev/null || echo ""
}

get_cloudwatch_alarms() {
    aws cloudwatch describe-alarms \
        --region "$AWS_REGION" \
        --query "MetricAlarms[?contains(AlarmName,'${ALARM_SUFFIX}')].AlarmName" \
        --output text 2>/dev/null || echo ""
}

# =====================================================================
# Main Analysis
# =====================================================================

main() {
    log "=========================================="
    log "Build Stage: Analyzing SQS Queues"
    log "=========================================="
    
    log "Fetching SQS queues..."
    queues=$(get_sqs_queues)
    
    log "Fetching CloudWatch alarms..."
    alarms=$(get_cloudwatch_alarms)
    
    # Build maps
    declare -A queue_map
    declare -A alarm_map
    
    for url in $queues; do
        q=$(extract_queue_name "$url")
        queue_map["$q"]=1
    done
    
    for alarm in $alarms; do
        alarm_map["$alarm"]=1
    done
    
    # Prepare plan
    create_list=()
    delete_list=()
    
    log ""
    log "Analyzing differences..."
    
    # Find alarms to create
    for q in "${!queue_map[@]}"; do
        expected_alarm="${q}${ALARM_SUFFIX}"
        if [[ -z "${alarm_map[$expected_alarm]:-}" ]]; then
            threshold=$(get_threshold "$q")
            create_list+=("{\"queue\":\"$q\",\"alarm\":\"$expected_alarm\",\"threshold\":$threshold}")
            log "  [CREATE] $expected_alarm (threshold: $threshold)"
        fi
    done
    
    # Find alarms to delete
    for alarm in "${!alarm_map[@]}"; do
        queue="${alarm%$ALARM_SUFFIX}"
        if [[ -z "${queue_map[$queue]:-}" ]]; then
            delete_list+=("\"$alarm\"")
            log "  [DELETE] $alarm (orphaned)"
        fi
    done
    
    # Generate plan.json
    log ""
    log "Generating deployment plan..."
    
    cat > plan.json <<EOF
{
  "region": "$AWS_REGION",
  "alarm_suffix": "$ALARM_SUFFIX",
  "create": [
    $(IFS=,; echo "${create_list[*]}")
  ],
  "delete": [
    $(IFS=,; echo "${delete_list[*]}")
  ],
  "summary": {
    "to_create": ${#create_list[@]},
    "to_delete": ${#delete_list[@]}
  }
}
EOF
    
    log "Plan saved to plan.json"
    log ""
    log "=========================================="
    log "Summary:"
    log "  Alarms to create: ${#create_list[@]}"
    log "  Alarms to delete: ${#delete_list[@]}"
    log "=========================================="
    
    # Show plan
    cat plan.json
}

main