# Twilio Extension for Kiket

Send SMS, MMS, and voice notifications using the Twilio messaging API with built-in rate limiting and opt-in management.

## Features

- **SMS Notifications**: Send text messages to any phone number
- **Voice Notifications**: Make automated voice calls with text-to-speech
- **MMS Notifications**: Send multimedia messages with images and videos
- **Opt-in Management**: Track user consent for notifications
- **Rate Limiting**: Prevent API abuse with configurable rate limits
- **Phone Number Validation**: Validate and normalize phone numbers
- **Delivery Tracking**: Track message delivery status via webhooks
- **Error Handling**: Comprehensive error handling with retry logic

## Prerequisites

- Ruby 3.2+
- Twilio account with:
  - Account SID
  - Auth Token
  - Phone number (SMS/Voice enabled)

## Installation

1. Clone the repository:
```bash
git clone https://github.com/kiket-dev/kiket-ext-twilio.git
cd kiket-ext-twilio
```

2. Install dependencies:
```bash
bundle install
```

3. Configure environment variables:
```bash
cp .env.example .env
# Edit .env with your Twilio credentials
```

4. Start the server:
```bash
bundle exec puma -C puma.rb
```

The extension will be available at `http://localhost:9393`

## Configuration

### Required Environment Variables

- `TWILIO_ACCOUNT_SID`: Your Twilio Account SID
- `TWILIO_AUTH_TOKEN`: Your Twilio Auth Token
- `TWILIO_PHONE_NUMBER`: Your Twilio phone number (E.164 format, e.g., +15551234567)

### Optional Environment Variables

- `TWILIO_MESSAGING_SERVICE_SID`: Messaging Service SID for advanced features
- `RATE_LIMIT_PER_MINUTE`: Maximum messages per minute (default: 10)
- `RETRY_ATTEMPTS`: Retry attempts for failed deliveries (default: 3)
- `TIMEOUT_SECONDS`: Request timeout (default: 30)
- `REQUIRE_OPT_IN`: Require opt-in before sending (default: true)
- `OPT_IN_STORAGE_METHOD`: Storage method for opt-in status (default: memory)
- `DEFAULT_COUNTRY_CODE`: Default country code for phone parsing (default: US)
- `ENABLE_DELIVERY_TRACKING`: Enable delivery status tracking (default: true)

## API Endpoints

### Send SMS

**POST** `/sms`

```json
{
  "to": "+15551234567",
  "message": "Hello from Kiket!"
}
```

**Response**:
```json
{
  "success": true,
  "message_sid": "SM1234567890abcdef",
  "to": "+15551234567",
  "status": "queued",
  "sent_at": "2025-11-10T12:00:00Z"
}
```

### Send Voice Call

**POST** `/voice`

```json
{
  "to": "+15551234567",
  "message": "This is an important notification from your team."
}
```

**Response**:
```json
{
  "success": true,
  "call_sid": "CA1234567890abcdef",
  "to": "+15551234567",
  "status": "queued",
  "initiated_at": "2025-11-10T12:00:00Z"
}
```

### Send MMS

**POST** `/mms`

```json
{
  "to": "+15551234567",
  "message": "Check out this image!",
  "media_urls": [
    "https://example.com/image.jpg"
  ]
}
```

**Response**:
```json
{
  "success": true,
  "message_sid": "MM1234567890abcdef",
  "to": "+15551234567",
  "status": "queued",
  "media_count": 1,
  "sent_at": "2025-11-10T12:00:00Z"
}
```

### Check Opt-in Status

**POST** `/opt-in/check`

```json
{
  "phone_number": "+15551234567"
}
```

**Response**:
```json
{
  "success": true,
  "phone_number": "+15551234567",
  "opted_in": true,
  "checked_at": "2025-11-10T12:00:00Z"
}
```

### Update Opt-in Status

**POST** `/opt-in/update`

```json
{
  "phone_number": "+15551234567",
  "opted_in": true
}
```

**Response**:
```json
{
  "success": true,
  "phone_number": "+15551234567",
  "opted_in": true,
  "updated_at": "2025-11-10T12:00:00Z"
}
```

### Validate Phone Number

**POST** `/validate`

```json
{
  "phone_number": "+1 (555) 123-4567"
}
```

**Response**:
```json
{
  "success": true,
  "phone_number": "+1 (555) 123-4567",
  "valid": true,
  "e164_format": "+15551234567",
  "country": "US",
  "national_format": "(555) 123-4567",
  "type": "mobile",
  "possible": true
}
```

### Health Check

**GET** `/health`

**Response**:
```json
{
  "status": "healthy",
  "service": "twilio-notifications",
  "version": "1.0.0",
  "timestamp": "2025-11-10T12:00:00Z",
  "twilio_configured": true
}
```

## Usage in Kiket Workflows

### SMS Notification Example

```yaml
workflow:
  name: Critical Alert
  states: [open, investigating, resolved]

  transitions:
    - from: open
      to: investigating
      actions:
        - extension: twilio-notifications.send_sms
          params:
            to: "{{ issue.assigned_user.phone }}"
            message: "ALERT: {{ issue.title }} - {{ issue.description }}"
```

### Voice Call Example

```yaml
workflow:
  name: On-Call Escalation
  states: [pending, escalated, acknowledged]

  transitions:
    - from: pending
      to: escalated
      actions:
        - extension: twilio-notifications.send_voice
          params:
            to: "{{ on_call_engineer.phone }}"
            message: "Critical incident: {{ incident.title }}. Please acknowledge immediately."
```

## Development

### Running Tests

```bash
bundle exec rspec
```

### Linting

```bash
bundle exec rubocop
```

### Docker Build

```bash
docker build -t kiket-ext-twilio .
docker run -p 9393:9393 --env-file .env kiket-ext-twilio
```

## Rate Limiting

The extension implements per-minute rate limiting to prevent abuse:

- Default: 10 messages per minute
- Configurable via `RATE_LIMIT_PER_MINUTE`
- Returns HTTP 400 with error message when exceeded
- Automatically resets after 60 seconds

## Opt-in Management

By default, the extension requires recipients to opt-in before receiving notifications:

1. **Enable/Disable**: Set `REQUIRE_OPT_IN=false` to disable
2. **Storage**: Currently uses in-memory storage (lost on restart)
3. **Production**: Implement database or Redis storage for persistence

To manage opt-ins:

```bash
# Add opt-in
curl -X POST http://localhost:9393/opt-in/update \
  -H "Content-Type: application/json" \
  -d '{"phone_number": "+15551234567", "opted_in": true}'

# Check opt-in status
curl -X POST http://localhost:9393/opt-in/check \
  -H "Content-Type: application/json" \
  -d '{"phone_number": "+15551234567"}'
```

## Error Handling

The extension returns appropriate HTTP status codes:

- **200**: Success
- **400**: Validation error (invalid input, opt-in required, rate limit exceeded)
- **502**: Twilio API error (network issues, invalid credentials)
- **500**: Internal server error

Error responses include detailed messages:

```json
{
  "success": false,
  "error": "Rate limit exceeded (10/min)"
}
```

## Delivery Status Tracking

The extension uses Kiket's **External Webhook Routing** to receive delivery status callbacks from Twilio. When `ENABLE_DELIVERY_TRACKING` is enabled (default), SMS and voice calls include a status callback URL.

### How It Works

1. When you send a message, Twilio is configured to send status updates to your installation's webhook URL
2. Kiket receives the callback and forwards it to this extension with a runtime token
3. The extension validates the Twilio signature and logs the delivery status

### Webhook URL

Each installation gets a unique webhook URL automatically:
```
https://kiket.dev/webhooks/ext/{webhook_token}/status_callback
```

You can find this URL in:
- Extension configuration page in Kiket
- Via API: `GET /api/v1/ext/webhook_url`

### Status Events

The extension logs the following status events:
- **SMS**: `queued`, `sent`, `delivered`, `undelivered`, `failed`
- **Voice**: `initiated`, `ringing`, `answered`, `completed`

## Security Considerations

1. **Credentials**: Never commit `.env` file - use environment variables
2. **Opt-in Compliance**: Ensure users have consented before sending notifications
3. **Rate Limiting**: Configure appropriate limits to prevent abuse
4. **Webhook Validation**: Twilio webhook signatures are automatically validated using your Auth Token
5. **HTTPS**: External webhook URLs are always HTTPS

## Deployment

### Docker Deployment

```bash
# Build image
docker build -t kiket-ext-twilio .

# Run container
docker run -d \
  -p 9393:9393 \
  -e TWILIO_ACCOUNT_SID=your_sid \
  -e TWILIO_AUTH_TOKEN=your_token \
  -e TWILIO_PHONE_NUMBER=+15551234567 \
  --name twilio-extension \
  kiket-ext-twilio
```

### Cloud Run Deployment

See `.github/workflows/deploy.yml` for automated deployment to Google Cloud Run.

## Troubleshooting

### "Twilio API error: Invalid phone number"

- Ensure phone numbers are in E.164 format (+15551234567)
- Use the `/validate` endpoint to check format

### "Rate limit exceeded"

- Increase `RATE_LIMIT_PER_MINUTE` or wait 60 seconds
- Consider implementing distributed rate limiting for multi-instance deployments

### "Recipient has not opted in"

- Set `REQUIRE_OPT_IN=false` or
- Use `/opt-in/update` to add the recipient

## License

MIT License - see LICENSE file for details

## Support

For issues and feature requests, please open an issue on GitHub:
https://github.com/kiket-dev/kiket-ext-twilio/issues
