#!/bin/bash
set -eo pipefail

# =====================================================================
# Multi-Resource Analysis Script - Build Stage
# This script analyzes alarms for:
# - SQS Queues
# - Lambda Functions
# - DynamoDB Tables
# Outputs: plan.txt (list of actions to take)
# NO EXTERNAL DEPENDENCIES - Pure bash only
# =====================================================================

AWS_REGION="${AWS_REGION:-us-east-1}"
ALARM_SUFFIX="-cloudwatch-alarm"
ALARM_THRESHOLD_SQS="${ALARM_THRESHOLD_SQS:-5}"
ALARM_THRESHOLD_LAMBDA="${ALARM_THRESHOLD_LAMBDA:-10}"
ALARM_THRESHOLD_DYNAMODB="${ALARM_THRESHOLD_DYNAMODB:-80}"

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

get_threshold_sqs() {
    if is_dlq "$1"; then echo "1"; else echo "$ALARM_THRESHOLD_SQS"; fi
}

# =====================================================================
# Fetch SQS Queues
# =====================================================================

get_sqs_queues() {
    log "Fetching SQS queues..."
    aws sqs list-queues \
        --region "$AWS_REGION" \
        --query 'QueueUrls' \
        --output text 2>/dev/null || echo ""
}

# =====================================================================
# Fetch Lambda Functions
# =====================================================================

get_lambda_functions() {
    log "Fetching Lambda functions..."
    aws lambda list-functions \
        --region "$AWS_REGION" \
        --query 'Functions[].FunctionName' \
        --output text 2>/dev/null || echo ""
}

# =====================================================================
# Fetch DynamoDB Tables
# =====================================================================

get_dynamodb_tables() {
    log "Fetching DynamoDB tables..."
    aws dynamodb list-tables \
        --region "$AWS_REGION" \
        --query 'TableNames' \
        --output text 2>/dev/null || echo ""
}

# =====================================================================
# Fetch CloudWatch Alarms
# =====================================================================

get_cloudwatch_alarms() {
    log "Fetching CloudWatch alarms..."
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
    log "Build Stage: Analyzing Resources"
    log "=========================================="
    
    # Fetch all resources
    local sqs_queues
    sqs_queues=$(get_sqs_queues)
    
    local lambda_functions
    lambda_functions=$(get_lambda_functions)
    
    local dynamodb_tables
    dynamodb_tables=$(get_dynamodb_tables)
    
    local alarms
    alarms=$(get_cloudwatch_alarms)
    
    # Build resource maps
    declare -A sqs_map
    declare -A lambda_map
    declare -A dynamodb_map
    declare -A alarm_map
    
    # Populate SQS queue map
    if [ -n "$sqs_queues" ]; then
        for url in $sqs_queues; do
            local q
            q=$(extract_queue_name "$url")
            sqs_map["$q"]=1
        done
    fi
    
    # Populate Lambda function map
    if [ -n "$lambda_functions" ]; then
        for func in $lambda_functions; do
            lambda_map["$func"]=1
        done
    fi
    
    # Populate DynamoDB table map
    if [ -n "$dynamodb_tables" ]; then
        for table in $dynamodb_tables; do
            dynamodb_map["$table"]=1
        done
    fi
    
    # Populate alarm map
    if [ -n "$alarms" ]; then
        for alarm in $alarms; do
            alarm_map["$alarm"]=1
        done
    fi
    
    # Prepare plan file
    > plan.txt
    echo "REGION=$AWS_REGION" >> plan.txt
    echo "ALARM_SUFFIX=$ALARM_SUFFIX" >> plan.txt
    echo "---CREATE---" >> plan.txt
    
    local create_count=0
    local delete_count=0
    
    log ""
    log "=========================================="
    log "Analyzing Resources..."
    log "=========================================="
    
    # ================================================================
    # Analyze SQS Queues
    # ================================================================
    
    log ""
    log "SQS Queues:"
    log "----------------------------------------"
    
    local sqs_count=${#sqs_map[@]}
    if [ "$sqs_count" -gt 0 ]; then
        for queue in "${!sqs_map[@]}"; do
            local expected_alarm="${queue}${ALARM_SUFFIX}"
            if [ -z "${alarm_map[$expected_alarm]+_}" ]; then
                local threshold
                threshold=$(get_threshold_sqs "$queue")
                echo "SQS|$queue|$expected_alarm|$threshold|ApproximateNumberOfMessagesVisible" >> plan.txt
                log "  [CREATE] $expected_alarm (SQS, threshold: $threshold messages)"
                create_count=$((create_count + 1))
            else
                log "  [EXISTS] $expected_alarm"
            fi
        done
    else
        log "  No SQS queues found"
    fi
    
    # ================================================================
    # Analyze Lambda Functions
    # ================================================================
    
    log ""
    log "Lambda Functions:"
    log "----------------------------------------"
    
    local lambda_count=${#lambda_map[@]}
    if [ "$lambda_count" -gt 0 ]; then
        for func in "${!lambda_map[@]}"; do
            local expected_alarm="${func}${ALARM_SUFFIX}"
            if [ -z "${alarm_map[$expected_alarm]+_}" ]; then
                echo "LAMBDA|$func|$expected_alarm|$ALARM_THRESHOLD_LAMBDA|Errors" >> plan.txt
                log "  [CREATE] $expected_alarm (Lambda, threshold: $ALARM_THRESHOLD_LAMBDA errors)"
                create_count=$((create_count + 1))
            else
                log "  [EXISTS] $expected_alarm"
            fi
        done
    else
        log "  No Lambda functions found"
    fi
    
    # ================================================================
    # Analyze DynamoDB Tables
    # ================================================================
    
    log ""
    log "DynamoDB Tables:"
    log "----------------------------------------"
    
    local dynamodb_count=${#dynamodb_map[@]}
    if [ "$dynamodb_count" -gt 0 ]; then
        for table in "${!dynamodb_map[@]}"; do
            local expected_alarm="${table}${ALARM_SUFFIX}"
            if [ -z "${alarm_map[$expected_alarm]+_}" ]; then
                echo "DYNAMODB|$table|$expected_alarm|$ALARM_THRESHOLD_DYNAMODB|ConsumedReadCapacityUnits" >> plan.txt
                log "  [CREATE] $expected_alarm (DynamoDB, threshold: $ALARM_THRESHOLD_DYNAMODB RCU)"
                create_count=$((create_count + 1))
            else
                log "  [EXISTS] $expected_alarm"
            fi
        done
    else
        log "  No DynamoDB tables found"
    fi
    
    # ================================================================
    # Find Orphaned Alarms
    # ================================================================
    
    log ""
    log "Orphaned Alarms:"
    log "----------------------------------------"
    
    echo "---DELETE---" >> plan.txt
    
    local alarm_count=${#alarm_map[@]}
    if [ "$alarm_count" -gt 0 ]; then
        for alarm in "${!alarm_map[@]}"; do
            local resource_name="${alarm%$ALARM_SUFFIX}"
            
            # Check if this alarm belongs to any existing resource
            local found=0
            
            if [ -n "${sqs_map[$resource_name]+_}" ]; then
                found=1
            elif [ -n "${lambda_map[$resource_name]+_}" ]; then
                found=1
            elif [ -n "${dynamodb_map[$resource_name]+_}" ]; then
                found=1
            fi
            
            if [ "$found" -eq 0 ]; then
                echo "$alarm" >> plan.txt
                log "  [DELETE] $alarm (no matching resource)"
                delete_count=$((delete_count + 1))
            fi
        done
        
        if [ "$delete_count" -eq 0 ]; then
            log "  No orphaned alarms found"
        fi
    else
        log "  No existing alarms to check"
    fi
    
    # ================================================================
    # Summary
    # ================================================================
    
    echo "---SUMMARY---" >> plan.txt
    echo "CREATE_COUNT=$create_count" >> plan.txt
    echo "DELETE_COUNT=$delete_count" >> plan.txt
    
    log ""
    log "=========================================="
    log "SUMMARY"
    log "=========================================="
    log "Resources Found:"
    log "  - SQS Queues:      $sqs_count"
    log "  - Lambda Functions: $lambda_count"
    log "  - DynamoDB Tables:  $dynamodb_count"
    log ""
    log "Actions Needed:"
    log "  - Alarms to create: $create_count"
    log "  - Alarms to delete: $delete_count"
    log "=========================================="
    
    # Show plan
    log ""
    log "=== PLAN CONTENTS ==="
    cat plan.txt
    log "=== END PLAN ==="
}

# Call main function
main