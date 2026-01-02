# Getting Started with Twilio SMS

Send SMS notifications for urgent alerts and approvals.

## Prerequisites

- Twilio account with SMS capabilities
- Twilio phone number

## Step 1: Get Twilio Credentials

1. Log in to [Twilio Console](https://console.twilio.com/)
2. Find your **Account SID** and **Auth Token** on the dashboard
3. Note your Twilio phone number

## Step 2: Configure in Kiket

1. Go to **Organization Settings → Extensions → Twilio**
2. Enter:
   - **Account SID**: Your Twilio Account SID
   - **Auth Token**: Your Twilio Auth Token
   - **From Number**: Your Twilio phone number (E.164 format)
3. Click **Test Connection**

## Step 3: Add User Phone Numbers

Users must have phone numbers configured in their profiles to receive SMS.

## Step 4: Add to Workflows

```yaml
automations:
  - name: sms_on_sla_breach
    trigger:
      event: workflow.sla_breach
      conditions:
        - field: sla.severity
          operator: eq
          value: "critical"
    actions:
      - extension: dev.kiket.ext.twilio
        command: twilio.sendSms
        params:
          to: "{{ issue.assignee.phone }}"
          message: "URGENT: SLA breach on {{ issue.title }}. Action required immediately."
```

## Rate Limits

SMS notifications are rate-limited to prevent abuse:
- 10 SMS per user per hour
- 100 SMS per organization per hour
