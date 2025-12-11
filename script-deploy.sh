#!/bin/bash
set -euo pipefail

# =====================================================================
# Deploy Script - Deploy Stage
# This script executes the plan created in the build stage
# Reads: plan.json
# Actions: Creates and deletes CloudWatch alarms
# =====================================================================

SNS_TOPIC_ARN="${SNS_TOPIC_ARN:-arn:aws:sns:us-east-1:860265990835:Alternative-Monitoring-Setup-SNS-Topic}"
ALARM_PERIOD=60

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# =====================================================================
# Load Plan
# =====================================================================

if [[ ! -f plan.json ]]; then
    log "ERROR: plan.json not found!"
    log "Make sure the Build stage completed successfully."
    exit 1
fi

log "Loading deployment plan..."
PLAN=$(cat plan.json)

AWS_REGION=$(echo "$PLAN" | jq -r '.region')
ALARM_SUFFIX=$(echo "$PLAN" | jq -r '.alarm_suffix')
CREATE_COUNT=$(echo "$PLAN" | jq -r '.summary.to_create')
DELETE_COUNT=$(echo "$PLAN" | jq -r '.summary.to_delete')

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
        --ok-actions "$SNS_TOPIC_ARN" 2>&1; then
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
        --alarm-names "$alarm_name" 2>&1; then
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
    
    created=0
    deleted=0
    failed=0
    
    # Create alarms
    if [[ "$CREATE_COUNT" -gt 0 ]]; then
        log "Phase 1: Creating Alarms"
        log "----------------------------------------"
        
        while IFS= read -r item; do
            queue=$(echo "$item" | jq -r '.queue')
            alarm=$(echo "$item" | jq -r '.alarm')
            threshold=$(echo "$item" | jq -r '.threshold')
            
            if create_alarm "$queue" "$alarm" "$threshold"; then
                ((created++))
            else
                ((failed++))
            fi
        done < <(echo "$PLAN" | jq -c '.create[]')
        
        log ""
    fi
    
    # Delete alarms
    if [[ "$DELETE_COUNT" -gt 0 ]]; then
        log "Phase 2: Deleting Orphaned Alarms"
        log "----------------------------------------"
        
        while IFS= read -r alarm; do
            alarm_name=$(echo "$alarm" | tr -d '"')
            
            if delete_alarm "$alarm_name"; then
                ((deleted++))
            else
                ((failed++))
            fi
        done < <(echo "$PLAN" | jq -c '.delete[]')
        
        log ""
    fi
    
    # Summary
    log "=========================================="
    log "Deployment Complete"
    log "=========================================="
    log "✓ Alarms created:  $created"
    log "✗ Alarms deleted:  $deleted"
    log "⚠ Failed operations: $failed"
    log "=========================================="
    
    # Send notification
    send_notification "$created" "$deleted" "$failed"
    
    if [[ $failed -gt 0 ]]; then
        exit 1
    fi
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

main