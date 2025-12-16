#!/bin/bash
set -eo pipefail  # Removed 'u' flag to avoid issues with variable expansion

# =====================================================================
# Deploy Script - Deploy Stage
# This script executes the plan created in the build stage
# Reads: plan.txt
# Actions: Creates and deletes CloudWatch alarms
# NO EXTERNAL DEPENDENCIES - Pure bash only
# =====================================================================

SNS_TOPIC_ARN="${SNS_TOPIC_ARN:-arn:aws:sns:us-east-1:860265990835:Alternative-Monitoring-Setup-SNS-Topic}"
ALARM_PERIOD=60

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# =====================================================================
# Load Plan
# =====================================================================

if [[ ! -f plan.txt ]]; then
    log "ERROR: plan.txt not found!"
    log "Make sure the Build stage completed successfully."
    exit 1
fi

log "Loading deployment plan..."

# Parse plan.txt
AWS_REGION=""
ALARM_SUFFIX=""
CREATE_COUNT=0
DELETE_COUNT=0

while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == REGION=* ]]; then
        AWS_REGION="${line#REGION=}"
    elif [[ "$line" == ALARM_SUFFIX=* ]]; then
        ALARM_SUFFIX="${line#ALARM_SUFFIX=}"
    elif [[ "$line" == CREATE_COUNT=* ]]; then
        CREATE_COUNT="${line#CREATE_COUNT=}"
    elif [[ "$line" == DELETE_COUNT=* ]]; then
        DELETE_COUNT="${line#DELETE_COUNT=}"
    fi
done < plan.txt

# =====================================================================
# Alarm Management
# =====================================================================

create_alarm() {
    local queue=$1
    local alarm_name=$2
    local threshold=$3
    
    log "Creating alarm: $alarm_name (threshold: $threshold)"
    
    if aws cloudwatch put-metric-alarm \
        --region "$AWS_REGION" \
        --alarm-name "$alarm_name" \
        --alarm-description "Alarm for SQS queue $queue" \
        --namespace "AWS/SQS" \
        --metric-name "ApproximateNumberOfMessagesVisible" \
        --dimensions "Name=QueueName,Value=$queue" \
        --statistic Average \
        --period "$ALARM_PERIOD" \
        --evaluation-periods 1 \
        --threshold "$threshold" \
        --comparison-operator GreaterThanThreshold \
        --treat-missing-data notBreaching \
        --alarm-actions "$SNS_TOPIC_ARN" \
        --ok-actions "$SNS_TOPIC_ARN" >/dev/null 2>&1; then
        log "✓ Created: $alarm_name"
        return 0
    else
        log "✗ Failed: $alarm_name"
        return 1
    fi
}

delete_alarm() {
    local alarm_name=$1
    
    log "Deleting alarm: $alarm_name"
    
    if aws cloudwatch delete-alarms \
        --region "$AWS_REGION" \
        --alarm-names "$alarm_name" >/dev/null 2>&1; then
        log "✓ Deleted: $alarm_name"
        return 0
    else
        log "✗ Failed to delete: $alarm_name"
        return 1
    fi
}

# =====================================================================
# Execute Plan
# =====================================================================

main() {
    log "=========================================="
    log "Deploy Stage: Executing Alarm Changes"
    log "=========================================="
    log "Region: $AWS_REGION"
    log "Alarms to create: $CREATE_COUNT"
    log "Alarms to delete: $DELETE_COUNT"
    log ""
    
    local created=0
    local deleted=0
    local failed=0
    
    # Parse plan and execute
    local section=""
    
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip config lines
        [[ "$line" == REGION=* ]] && continue
        [[ "$line" == ALARM_SUFFIX=* ]] && continue
        [[ "$line" == CREATE_COUNT=* ]] && continue
        [[ "$line" == DELETE_COUNT=* ]] && continue
        
        # Track sections
        if [[ "$line" == "---CREATE---" ]]; then
            section="create"
            if [[ "$CREATE_COUNT" -gt 0 ]]; then
                log "Phase 1: Creating Alarms"
                log "----------------------------------------"
            fi
            continue
        elif [[ "$line" == "---DELETE---" ]]; then
            section="delete"
            if [[ "$DELETE_COUNT" -gt 0 ]]; then
                log ""
                log "Phase 2: Deleting Orphaned Alarms"
                log "----------------------------------------"
            fi
            continue
        elif [[ "$line" == "---SUMMARY---" ]]; then
            break
        fi
        
        # Skip empty lines
        [[ -z "$line" ]] && continue
        
        # Execute actions
        if [[ "$section" == "create" ]]; then
            # Format: queue|alarm|threshold
            IFS='|' read -r queue alarm threshold <<< "$line"
            if [[ -n "$queue" && -n "$alarm" && -n "$threshold" ]]; then
                if create_alarm "$queue" "$alarm" "$threshold"; then
                    created=$((created + 1))
                else
                    failed=$((failed + 1))
                fi
            fi
        elif [[ "$section" == "delete" ]]; then
            # Format: alarm_name
            if [[ -n "$line" ]]; then
                if delete_alarm "$line"; then
                    deleted=$((deleted + 1))
                else
                    failed=$((failed + 1))
                fi
            fi
        fi
    done < plan.txt
    
    log ""
    log "=========================================="
    log "Deployment Complete"
    log "=========================================="
    log "✓ Alarms created:  $created"
    log "✗ Alarms deleted:  $deleted"
    log "⚠ Failed operations: $failed"
    log "=========================================="
    
    # Send notification
    send_notification "$created" "$deleted" "$failed"
    
    # Exit with success even if some operations failed (unless all failed)
    local total_operations=$((CREATE_COUNT + DELETE_COUNT))
    if [[ $failed -eq $total_operations && $total_operations -gt 0 ]]; then
        log "ERROR: All operations failed!"
        exit 1
    fi
    
    log "Script completed successfully"
    exit 0
}

send_notification() {
    local created=$1
    local deleted=$2
    local failed=$3
    
    local message="SQS Alarm Deployment Complete

Region: $AWS_REGION
Timestamp: $(date '+%Y-%m-%d %H:%M:%S')

Results:
✓ Created: $created
✗ Deleted: $deleted
⚠ Failed: $failed

Pipeline execution completed successfully."
    
    aws sns publish \
        --topic-arn "$SNS_TOPIC_ARN" \
        --subject "SQS Alarms Deployed: $created created, $deleted deleted" \
        --message "$message" \
        --region "$AWS_REGION" >/dev/null 2>&1 || log "Warning: Failed to send notification"
}

# Call main function
main