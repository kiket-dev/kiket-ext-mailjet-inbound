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
3. Extension uses the runtime token for authenticated API calls
4. **No Extension API Keys required** - runtime tokens provide per-invocation auth

## Setup

### 1. Install the Extension

Install the extension from the Kiket Marketplace or via CLI:

```bash
kiket extension install dev.kiket.ext.mailjet-inbound
```

### 2. Get Your Webhook URL

After installation, retrieve your unique webhook URL. You can do this:

**Via Kiket UI:**
- Go to **Project Settings** → **Extensions** → **Mailjet Inbound** → **Webhook URL**

**Via API:**
```bash
# Using a runtime token (from extension invocation context)
curl -H "X-Kiket-Runtime-Token: $RUNTIME_TOKEN" \
  "https://kiket.dev/api/v1/ext/webhook_url?action_name=inbound_email"
```

This returns:
```json
{
  "webhook_url": "https://kiket.dev/webhooks/ext/abc123token/inbound_email",
  "webhook_token": "abc123token",
  "webhook_base_url": "https://kiket.dev/webhooks/ext/abc123token"
}
```

### 3. Configure DNS

Add an MX record for your inbound email domain:

```
inbound.kiket.dev.  MX  10  parse.mailjet.com.
```

Verify propagation:
```bash
dig MX inbound.kiket.dev +short
# Expected: 10 parse.mailjet.com.
```

### 4. Configure Mailjet Parse API

The Parse API is configured via Mailjet's REST API. You'll need your Mailjet API credentials.

> **Note:** Parse API requires a paid Mailjet plan (Crystal or above).

**Get your API credentials:**
1. Log in to [Mailjet Dashboard](https://app.mailjet.com)
2. Go to **Account Settings** → **API Key Management**
3. Copy your API Key and Secret Key

**Create a parse route:**

```bash
export MAILJET_API_KEY="your_api_key"
export MAILJET_SECRET_KEY="your_secret_key"

curl -X POST \
  --user "$MAILJET_API_KEY:$MAILJET_SECRET_KEY" \
  https://api.mailjet.com/v3/REST/parseroute \
  -H "Content-Type: application/json" \
  -d '{
    "Url": "https://kiket.dev/webhooks/ext/YOUR_TOKEN/inbound_email",
    "Email": "incoming@inbound.kiket.dev"
  }' | jq .
```

Replace:
- `your_api_key` and `your_secret_key` with your Mailjet credentials
- `YOUR_TOKEN` with your webhook token from Step 2
- `incoming@inbound.kiket.dev` with your desired inbound email address

**Verify the route was created:**

```bash
curl --user "$MAILJET_API_KEY:$MAILJET_SECRET_KEY" \
  https://api.mailjet.com/v3/REST/parseroute | jq .
```

For more details, see the [Mailjet Parse API documentation](https://dev.mailjet.com/email/guides/parse-api/).

### 5. (Optional) Additional Security

**Use HTTPS with Basic Auth:**

Mailjet recommends using basic authentication in your webhook URL for added security:

```bash
curl -s -X POST \
  --user "$MAILJET_API_KEY:$MAILJET_SECRET_KEY" \
  https://api.mailjet.com/v3/REST/parseroute \
  -d '{
    "Url": "https://username:password@kiket.dev/webhooks/ext/YOUR_TOKEN/inbound_email",
    "Email": "incoming@inbound.kiket.dev"
  }'
```

> **Note:** Kiket's webhook URLs are already protected by unique tokens. Basic auth provides an additional layer of security but is optional.

## Email Routing

Emails are routed to organizations based on subdomain:

- `support@acme.inbound.kiket.dev` → Organization with subdomain `acme`
- `bugs@widgets.inbound.kiket.dev` → Organization with subdomain `widgets`

The local part (e.g., `support`, `bugs`) is matched against `EmailAddressMapping` configurations.

## Token Rotation

If your webhook URL is compromised, you can rotate the token:

```bash
curl -X POST -H "X-Kiket-Runtime-Token: $RUNTIME_TOKEN" \
  "https://kiket.dev/api/v1/ext/webhook_url/rotate"
```

This returns a new webhook URL. Remember to update your Mailjet configuration.

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
  "registered_events": ["external.webhook.inbound_email"]
}
```

## License

MIT
