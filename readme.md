# Automated CloudWatch Alarm Management for SQS Queues

> **Event-driven, manually-controlled alarm management system with email notifications**
![image alt](https://github.com/SimranBanwait/Alternative-Monitoring-Setup/blob/1254b31ed78edbfbad98c614d624229b47d264ae/assets/4-Setup.png)

---

## 🎯 What Does This Do?

This system automatically manages CloudWatch alarms for your SQS queues:

1. **Detects** when queues are created/deleted via CloudTrail + EventBridge
2. **Notifies** your team via email
3. **Waits** for you to manually trigger the pipeline
4. **Reconciles** all alarms in one batch
5. **Confirms** with a summary email

### The Problem It Solves

- ❌ Manually creating alarms for every new queue is tedious
- ❌ Forgetting to delete alarms for deleted queues wastes money
- ❌ Inconsistent alarm configurations across queues
- ❌ No visibility when queues are created/deleted

### The Solution

- ✅ Automatic detection of queue lifecycle events
- ✅ Standardized alarms for all queues
- ✅ Automatic cleanup of orphaned alarms
- ✅ Full manual control - you decide when to run
- ✅ Email notifications at every step

---

## 📊 Architecture


```
SQS Queue Created/Deleted
    ↓
CloudTrail logs event (30 sec delay)
    ↓
EventBridge detects event
    ↓
SNS emails DevOps team
    ↓
Engineer triggers CodePipeline manually
    ↓
BUILD STAGE: script-analyze.sh
├─ Lists all queues
├─ Lists all alarms
├─ Finds missing alarms
├─ Finds orphaned alarms
└─ Generates plan.txt
    ↓
DEPLOY STAGE: script-deploy.sh
├─ Creates missing alarms
├─ Deletes orphaned alarms
└─ Sends completion email
```

---

## ✨ Features

- 🔔 **Email notifications** for queue changes and deployment results
- 🎮 **Manual control** - nothing happens without your approval
- 📦 **Batch processing** - reconciles all queues in single run
- 🧠 **Smart thresholds** - DLQs get threshold of 1, normal queues get 5
- ♻️ **Idempotent** - safe to run multiple times
- 🧹 **Auto-cleanup** - removes orphaned alarms automatically
- 📝 **Detailed logging** - full audit trail in CloudWatch Logs

---

## 📋 Prerequisites

### Required AWS Services
- CloudTrail (logging enabled)
- SNS (email notifications)
- EventBridge (event detection)
- CodePipeline + CodeBuild (execution)
- IAM (permissions)

### Required Accounts & Tools
- AWS Account with admin access
- GitHub account
- AWS CLI configured
- Git installed
- Email address for notifications

---

## 🚀 Setup Guide

### Phase 1: Enable CloudTrail

**Purpose:** Records all AWS API calls for EventBridge to monitor

1. Go to **CloudTrail** → **Trails** → **Create trail**
2. Settings:
   - Name: `management-events-trail`
   - S3 bucket: Create new `cloudtrail-logs-YOUR-ACCOUNT-ID`
   - Log file encryption: Disabled (free tier)
3. Log events: Management events (Read + Write), no data events
4. Create trail

![CloudTrail Setup](screenshots/cloudtrail-create.png)
![image alt](https://github.com/SimranBanwait/Automated-CloudWatch-Alarm-Management/blob/4d3a0424d5ed4af52dcdbcc1761a4b9f3335fd80/assets/6-Cloudtrail.png)


**Cost:** FREE (first trail with management events)

---

### Phase 2: Create SNS Topic

**Purpose:** Sends email notifications

1. **SNS** → **Topics** → **Create topic**
2. Type: Standard, Name: `sqs-queue-change-notifications`
3. **Create subscription:**
   - Protocol: Email
   - Endpoint: `your-email@company.com`
4. Confirm subscription via email
5. Edit topic **Access policy**, add:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowEventBridgePublish",
      "Effect": "Allow",
      "Principal": {"Service": "events.amazonaws.com"},
      "Action": "SNS:Publish",
      "Resource": "arn:aws:sns:REGION:ACCOUNT-ID:sqs-queue-change-notifications"
    }
  ]
}
```

![SNS Setup](screenshots/sns-topic-create.png)

**Test it:**
```bash
aws sns publish \
  --topic-arn arn:aws:sns:us-east-1:ACCOUNT-ID:sqs-queue-change-notifications \
  --subject "Test" \
  --message "SNS working!" \
  --region us-east-1
```

---

### Phase 3: Create EventBridge Rule

**Purpose:** Detects queue creation/deletion and triggers SNS

1. **EventBridge** → **Rules** → **Create rule**
2. Name: `sqs-queue-lifecycle-alert`
3. Event pattern (JSON):

```json
{
  "source": ["aws.sqs"],
  "detail-type": ["AWS API Call via CloudTrail"],
  "detail": {
    "eventSource": ["sqs.amazonaws.com"],
    "eventName": ["CreateQueue", "DeleteQueue"]
  }
}
```

4. Target: SNS topic → `sqs-queue-change-notifications`
5. Configure **Input transformer:**

**Input paths:**
```json
{
  "eventName": "$.detail.eventName",
  "queueName": "$.detail.requestParameters.queueName",
  "queueUrl": "$.detail.requestParameters.queueUrl",
  "userName": "$.detail.userIdentity.userName",
  "eventTime": "$.time"
}
```

**Template:**
```
SQS Queue Alert

Action: <eventName>
Queue: <queueName>
By: <userName>
Time: <eventTime>

To reconcile alarms, run:
aws codepipeline start-pipeline-execution --name sqs-alarm-pipeline --region us-east-1

Or visit: https://console.aws.amazon.com/codesuite/codepipeline/pipelines/sqs-alarm-pipeline
```

![EventBridge Setup](screenshots/eventbridge-rule.png)

---

### Phase 4: Setup GitHub Repository

1. Create repo: `sqs-alarm-automation` (Private)
2. Add these files:

**`script-analyze.sh`** - [See attached file]
**`script-deploy.sh`** - [See attached file]
**`buildspec-build.yaml`** - [See attached file]
**`buildspec-deploy.yaml`** - [See attached file]

3. Make executable:
```bash
chmod +x script-analyze.sh script-deploy.sh
git add .
git commit -m "Initial commit"
git push
```

![GitHub Files](screenshots/github-repo-files.png)

---

### Phase 5: Create CodeBuild Projects

#### Build Project (Analysis)

1. **CodeBuild** → **Create project**
2. Settings:
   - Name: `sqs-alarm-build`
   - Source: GitHub → `sqs-alarm-automation`
   - Environment: Ubuntu, Standard:7.0, Linux
   - Buildspec: `buildspec-build.yaml`
   - Service role: New role (auto-generated)

![CodeBuild Build Project](screenshots/codebuild-build-project.png)

#### Deploy Project (Execution)

1. Create another project:
   - Name: `sqs-alarm-deploy`
   - Source: Same GitHub repo
   - Environment: Same settings, **Reuse same service role**
   - Buildspec: `buildspec-deploy.yaml`

![CodeBuild Deploy Project](screenshots/codebuild-deploy-project.png)

---

### Phase 6: Create CodePipeline

1. **CodePipeline** → **Create pipeline**
2. Name: `sqs-alarm-pipeline`
3. **Source stage:**
   - Provider: GitHub (Version 2)
   - Repo: `sqs-alarm-automation`
   - Branch: `main`
4. **Build stage:**
   - Provider: CodeBuild
   - Project: `sqs-alarm-build`
5. **Deploy stage:**
   - Provider: CodeBuild
   - Project: `sqs-alarm-deploy`

![CodePipeline Setup](screenshots/codepipeline-overview.png)

Optional: Disable auto-start for full manual control

---

### Phase 7: Configure IAM Permissions

1. **IAM** → **Roles** → Find `codebuild-sqs-alarm-build-service-role`
2. **Add inline policy:**

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "SQSList",
            "Effect": "Allow",
            "Action": [
                "sqs:ListQueues",
                "sts:GetCallerIdentity"
            ],
            "Resource": "*"
        },
        {
            "Sid": "CloudWatchAlarmManagement",
            "Effect": "Allow",
            "Action": [
                "cloudwatch:DescribeAlarms",
                "cloudwatch:PutMetricAlarm",
                "cloudwatch:DeleteAlarms"
            ],
            "Resource": "*"
        },
        {
            "Sid": "SNSPublish",
            "Effect": "Allow",
            "Action": "sns:Publish",
            "Resource": "arn:aws:sns:*:*:*"
        },
        {
            "Sid": "S3Artifacts",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:GetBucketLocation"
            ],
            "Resource": "arn:aws:s3:::YOUR-PIPELINE-BUCKET/*"
        },
        {
            "Sid": "CloudWatchLogs",
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": "*"
        }
    ]
}
```

![IAM Policy](screenshots/iam-policy.png)

3. **Add environment variables** to both CodeBuild projects:
   - `AWS_REGION`: `us-east-1`
   - `ALARM_THRESHOLD`: `5`
   - `SNS_TOPIC_ARN`: `arn:aws:sns:us-east-1:ACCOUNT-ID:sqs-queue-change-notifications`

---

## ✅ Testing

### Test 1: Create Queue

```bash
aws sqs create-queue --queue-name test-automation-1 --region us-east-1
```

**Expected:**
1. Wait ~30-60 seconds
2. Receive email: "SQS Queue Alert - CreateQueue"
3. Run pipeline: `aws codepipeline start-pipeline-execution --name sqs-alarm-pipeline --region us-east-1`
4. Check logs in CodeBuild
5. Verify alarm created: `aws cloudwatch describe-alarms --alarm-name-prefix "test-automation-1"`
6. Receive summary email

![Test Results](screenshots/test-create-queue.png)

### Test 2: Create DLQ (Lower Threshold)

```bash
aws sqs create-queue --queue-name orders-queue-dlq --region us-east-1
```

**Expected:** Alarm created with threshold = 1 (instead of 5)

### Test 3: Delete Queue

```bash
QUEUE_URL=$(aws sqs get-queue-url --queue-name test-automation-1 --query 'QueueUrl' --output text)
aws sqs delete-queue --queue-url "$QUEUE_URL"
```

**Expected:**
1. Receive email notification
2. Run pipeline
3. Alarm deleted automatically

---

## 📖 Daily Usage

### When Queue is Created

1. **Receive email:**
   ```
   SQS Queue Alert
   
   Action: CreateQueue
   Queue: production-orders
   By: john.doe
   
   To reconcile alarms, run:
   aws codepipeline start-pipeline-execution --name sqs-alarm-pipeline
   ```

2. **Run pipeline** (via CLI or Console)

3. **Check results** in email:
   ```
   SQS Alarm Deployment Complete
   
   ✓ Created: 1
   ✗ Deleted: 0
   ⚠ Failed: 0
   ```

### Manual Pipeline Trigger

**Via CLI:**
```bash
aws codepipeline start-pipeline-execution \
  --name sqs-alarm-pipeline \
  --region us-east-1
```

**Via Console:**
1. Go to CodePipeline → `sqs-alarm-pipeline`
2. Click **Release change**

![Manual Trigger](screenshots/manual-trigger.png)

---

## 🔧 Troubleshooting

### Issue: Not receiving emails

**Check:**
1. SNS subscription confirmed? (Check SNS console)
2. Email in spam folder?
3. Test SNS manually: `aws sns publish ...`
4. EventBridge rule enabled?

### Issue: Pipeline fails at Build stage

**Check:**
1. GitHub connection working?
2. `buildspec-build.yaml` exists in repo?
3. Scripts executable? (`chmod +x`)
4. CloudWatch Logs: `/aws/codebuild/sqs-alarm-build`

### Issue: No alarms created

**Check:**
1. IAM permissions correct?
2. `plan.txt` generated? (Check Build stage artifacts)
3. Deploy stage logs show "Creating alarm"?
4. Try creating alarm manually to test permissions

### Issue: "None-cloudwatch-alarm" created

**Fixed in latest version** - script now filters out empty/None values

---

## 💰 Cost Breakdown

| Service | Usage | Monthly Cost |
|---------|-------|-------------|
| CloudTrail | First trail (management events) | **FREE** |
| EventBridge | Custom rules | **FREE** |
| SNS | ~100 emails/month | <$1 |
| CodeBuild | ~20 runs × 30 sec | ~$0.05 |
| CodePipeline | 1 pipeline | $1 |
| CloudWatch Alarms | $0.10 per alarm | $0.10 × N queues |

**Total for 50 queues: ~$7/month**

---

## 🎛️ Customization

### Change Alarm Thresholds

Edit environment variables in CodeBuild projects:
- `ALARM_THRESHOLD`: Default threshold (currently 5)
- DLQ threshold hardcoded to 1 in `script-analyze.sh`

### Change Alarm Period

Edit `script-deploy.sh` line 11:
```bash
ALARM_PERIOD=60  # Change to 300 for 5 minutes
```

### Add More Services

Currently supports SQS only. To add Lambda/DynamoDB:
1. Uncomment multi-resource code in `script-analyze.sh`
2. Update `script-deploy.sh` to handle multiple resource types
3. Add IAM permissions for Lambda/DynamoDB

### Custom Alarm Naming

Edit `script-analyze.sh` line 11:
```bash
ALARM_SUFFIX="-cloudwatch-alarm"  # Change suffix
```

---

## 📁 File Structure

```
sqs-alarm-automation/
├── README.md                    # This file
├── script-analyze.sh            # Build stage: Analyzes queues & alarms
├── script-deploy.sh             # Deploy stage: Creates/deletes alarms
├── buildspec-build.yaml         # CodeBuild build stage config
├── buildspec-deploy.yaml        # CodeBuild deploy stage config
└── screenshots/                 # Documentation images
    ├── architecture-overview.png
    ├── cloudtrail-create.png
    └── ...
```

---

## 🔐 Security Best Practices

- ✅ Use IAM roles, never hardcode credentials
- ✅ Limit IAM permissions to minimum required
- ✅ Use private GitHub repository
- ✅ Enable CloudTrail encryption (if handling sensitive data)
- ✅ Review CloudWatch Logs regularly
- ✅ Enable MFA on AWS accounts

---

## 🤝 Contributing

1. Fork the repository
2. Create feature branch: `git checkout -b feature-name`
3. Commit changes: `git commit -m "Add feature"`
4. Push to branch: `git push origin feature-name`
5. Submit pull request

---

## 📝 License

MIT License - See LICENSE file for details

---

## 📧 Support

For questions or issues:
- Open GitHub issue
- Contact: devops-team@company.com

---

## 🙏 Acknowledgments

Built with:
- AWS CloudTrail
- AWS EventBridge
- AWS CodePipeline
- AWS CodeBuild
- AWS SNS
- Bash scripting

---

**Last Updated:** December 2025

**Version:** 1.0.0
