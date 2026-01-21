# Mailjet Inbound Email Extension

Process inbound emails from Mailjet Parse API and create issues or comments in Kiket.

## Overview

This extension receives emails forwarded by Mailjet's Parse API through Kiket's **External Webhook Routing** and:
- Normalizes the Mailjet payload to Kiket's standard format
- Calls Kiket's API to create issues from new emails
- Adds comments to existing issues for email replies
- Supports sender policy enforcement and auto-replies

## Architecture

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  Incoming   │───▶│   Mailjet   │───▶│    Kiket    │───▶│  Extension  │
│   Email     │    │  Parse API  │    │  (Webhook   │    │  (This app) │
└─────────────┘    └─────────────┘    │   Router)   │    └─────────────┘
                                      └─────────────┘
                                            │
                                            ▼
                                      Issues/Comments
                                       created in Kiket
```

With External Webhook Routing:
1. Mailjet sends webhooks to Kiket's external webhook URL
2. Kiket issues a **runtime token** and forwards to this extension
3. Extension processes the payload and calls Kiket API using the runtime token
4. **No Extension API Keys required** - runtime tokens provide per-invocation auth

## Setup

### Prerequisites

- A Mailjet account with a **paid plan** (Crystal or above) that includes Parse API
- Your Mailjet API credentials (API Key and Secret Key)

### 1. Install the Extension

Install the extension from the Kiket Marketplace or via CLI:

```bash
kiket extension install dev.kiket.ext.mailjet-inbound
```

### 2. Configure via Setup Wizard

The setup wizard will guide you through:

1. **Mailjet API Credentials** - Enter your API Key and Secret Key from [Mailjet Dashboard](https://app.mailjet.com) → **Account Settings** → **API Key Management**

2. **Email Processing Settings** - Configure:
   - Default project for new issues
   - Default issue type
   - Whether to accept emails from unknown senders

3. **Connect to Mailjet** - Click the button to automatically create the Parse API route in your Mailjet account

4. **DNS Configuration** - Follow the instructions to set up MX records

### 3. Configure DNS

Add an MX record for your inbound email domain:

```
inbound.yourdomain.com.  MX  10  parse.mailjet.com.
```

Verify propagation:
```bash
dig MX inbound.yourdomain.com +short
# Expected: 10 parse.mailjet.com.
```

DNS changes may take up to 48 hours to propagate.

## Manual Setup (Alternative)

If you prefer to configure Mailjet manually instead of using the automated setup:

### Get Your Webhook URL

After installation, find your webhook URL in **Project Settings** → **Extensions** → **Mailjet Inbound** → **Configure**.

Copy the **External Webhook URL** displayed in the sidebar.

### Create Parse Route via API

```bash
export MAILJET_API_KEY="your_api_key"
export MAILJET_SECRET_KEY="your_secret_key"

curl -X POST \
  --user "$MAILJET_API_KEY:$MAILJET_SECRET_KEY" \
  https://api.mailjet.com/v3/REST/parseroute \
  -H "Content-Type: application/json" \
  -d '{
    "Url": "https://kiket.dev/webhooks/ext/YOUR_TOKEN/inbound_email",
    "Email": "incoming@inbound.yourdomain.com"
  }' | jq .
```

For more details, see the [Mailjet Parse API documentation](https://dev.mailjet.com/email/guides/parse-api/).

## Email Routing

Emails are routed to organizations based on subdomain:

- `support@acme.inbound.kiket.dev` → Organization with subdomain `acme`
- `bugs@widgets.inbound.kiket.dev` → Organization with subdomain `widgets`

The local part (e.g., `support`, `bugs`) is matched against `EmailAddressMapping` configurations.

## Token Rotation

If your webhook URL is compromised, you can rotate the token in **Project Settings** → **Extensions** → **Mailjet Inbound** → **Configure** → **Rotate**.

After rotating, you'll need to update your Mailjet Parse route with the new URL.

## Development

### Prerequisites

- Ruby 3.4+
- Bundler

### Setup

```bash
bundle install
cp .env.example .env
# Edit .env with your configuration
```

### Run locally

```bash
bundle exec puma
```

### Run tests

```bash
bundle exec rspec
```

## Event Handling

This extension handles the `external.webhook.inbound_email` event, which receives Mailjet webhooks routed through Kiket's External Webhook system.

**Payload structure:**
```json
{
  "event": "external.webhook.inbound_email",
  "action": "inbound_email",
  "external_webhook": {
    "body": "{ Mailjet JSON payload }",
    "headers": { "X-Mailjet-Token": "..." },
    "content_type": "application/json",
    "method": "POST",
    "query_params": {}
  },
  "received_at": "2026-01-17T10:30:00Z",
  "authentication": {
    "runtime_token": "..."
  },
  "secrets": {
    "MAILJET_WEBHOOK_TOKEN": "..."
  }
}
```

## API Reference

### GET /health

Health check endpoint.

**Response:**
```json
{
  "status": "ok",
  "extension_id": "dev.kiket.ext.mailjet-inbound",
  "registered_events": ["external.webhook.inbound_email", "mailjet.connectParseApi"]
}
```

## Troubleshooting

### "Access denied" or 403 error during setup

Your Mailjet plan may not include Parse API. Parse API requires a paid plan (Crystal or above).

### "Invalid API credentials" error

Double-check your MAILJET_API_KEY and MAILJET_SECRET_KEY. You can find these in [Mailjet Dashboard](https://app.mailjet.com) → **Account Settings** → **API Key Management**.

### Emails not being received

1. Verify DNS MX records are correctly configured: `dig MX yourdomain.com +short`
2. Check that the Parse route was created in Mailjet
3. Verify the webhook URL is correct in Mailjet's Parse route

## License

MIT
