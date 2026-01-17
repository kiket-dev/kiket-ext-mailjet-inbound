# frozen_string_literal: true

require "spec_helper"

RSpec.describe MailjetInboundExtension do
  let(:app) { MailjetInboundExtension.new.app }

  # Build external webhook payload as Kiket would send it
  def build_webhook_payload(mailjet_payload, headers: {}, content_type: "application/json")
    {
      "event" => "external.webhook.inbound_email",
      "action" => "inbound_email",
      "external_webhook" => {
        "body" => mailjet_payload.to_json,
        "headers" => headers,
        "content_type" => content_type,
        "method" => "POST",
        "query_params" => {}
      },
      "received_at" => Time.now.iso8601,
      "authentication" => {
        "runtime_token" => "test_runtime_token_abc123"
      },
      "api" => {
        "base_url" => "https://kiket.test"
      },
      "secrets" => {}
    }
  end

  def make_webhook_request(payload, headers = {})
    post "/v/v1/webhooks/external.webhook.inbound_email", payload.to_json, {
      "CONTENT_TYPE" => "application/json"
    }.merge(headers)
  end

  before do
    # Stub JWT verification
    allow(KiketSDK::Auth).to receive(:verify_runtime_token).and_return({
      "exp" => (Time.now + 3600).to_i,
      "scopes" => [ "*" ],
      "org_id" => 1,
      "ext_id" => "dev.kiket.ext.mailjet-inbound",
      "proj_id" => 1
    })

    # Stub API calls
    stub_request(:post, "https://kiket.test/api/v1/ext/inbound_emails")
      .to_return(status: 200, body: { id: 123, status: "pending" }.to_json)

    stub_request(:post, %r{https://kiket.test/api/v1/ext/events})
      .to_return(status: 200, body: { ok: true }.to_json)
  end

  describe "POST /v/v1/webhooks/external.webhook.inbound_email" do
    let(:mailjet_payload) do
      {
        "MessageID" => "<abc123@mailjet.com>",
        "From" => "John Doe <john@example.com>",
        "To" => "support@acme.inbound.kiket.dev",
        "Subject" => "Help with my order",
        "Text-part" => "I need help with order #12345",
        "Html-part" => "<p>I need help with order #12345</p>",
        "Headers" => { "X-Custom" => "value" }.to_json
      }
    end

    it "accepts valid external webhook payloads" do
      payload = build_webhook_payload(mailjet_payload)
      make_webhook_request(payload)
      expect(last_response.status).to eq(200)
    end

    it "returns the created inbound email id" do
      payload = build_webhook_payload(mailjet_payload)
      make_webhook_request(payload)
      body = JSON.parse(last_response.body)
      expect(body["id"]).to eq(123)
    end

    it "normalizes the payload correctly" do
      payload = build_webhook_payload(mailjet_payload)
      make_webhook_request(payload)

      expect(WebMock).to have_requested(:post, "https://kiket.test/api/v1/ext/inbound_emails")
        .with { |req|
          body = JSON.parse(req.body)
          email = body["inbound_email"]
          email["message_id"] == "<abc123@mailjet.com>" &&
            email["from_email"] == "john@example.com" &&
            email["from_name"] == "John Doe" &&
            email["to_email"] == "support@acme.inbound.kiket.dev" &&
            email["subject"] == "Help with my order"
        }
    end

    it "uses runtime token for API calls" do
      payload = build_webhook_payload(mailjet_payload)
      make_webhook_request(payload)

      expect(WebMock).to have_requested(:post, "https://kiket.test/api/v1/ext/inbound_emails")
        .with(headers: { "X-Kiket-Runtime-Token" => "test_runtime_token_abc123" })
    end

    context "with webhook token verification" do
      before do
        # Simulate MAILJET_WEBHOOK_TOKEN secret being present
        allow_any_instance_of(MailjetInboundExtension).to receive(:secure_compare) do |_instance, a, b|
          a == b
        end
      end

      it "accepts requests with valid token in headers" do
        payload = build_webhook_payload(
          mailjet_payload,
          headers: { "X-Mailjet-Token" => "secret_token" }
        )
        payload["secrets"] = { "MAILJET_WEBHOOK_TOKEN" => "secret_token" }

        make_webhook_request(payload)
        expect(last_response.status).to eq(200)
      end

      it "rejects requests with invalid token" do
        payload = build_webhook_payload(
          mailjet_payload,
          headers: { "X-Mailjet-Token" => "wrong_token" }
        )
        payload["secrets"] = { "MAILJET_WEBHOOK_TOKEN" => "secret_token" }

        make_webhook_request(payload)
        body = JSON.parse(last_response.body)
        expect(body["ok"]).to eq(false)
        expect(body["error"]).to eq("Unauthorized")
      end

      it "accepts requests without token when secret not configured" do
        payload = build_webhook_payload(mailjet_payload)
        # No secrets in payload, no ENV var

        make_webhook_request(payload)
        expect(last_response.status).to eq(200)
      end
    end

    context "with reply email" do
      let(:reply_payload) do
        mailjet_payload.merge(
          "InReplyTo" => "<original123@mailjet.com>",
          "Subject" => "Re: Help with my order"
        )
      end

      it "includes in_reply_to in normalized payload" do
        payload = build_webhook_payload(reply_payload)
        make_webhook_request(payload)

        expect(WebMock).to have_requested(:post, "https://kiket.test/api/v1/ext/inbound_emails")
          .with { |req|
            body = JSON.parse(req.body)
            body["inbound_email"]["in_reply_to"] == "<original123@mailjet.com>"
          }
      end
    end

    context "with form-urlencoded content" do
      it "handles form-urlencoded Mailjet payloads" do
        form_body = URI.encode_www_form({
          "MessageID" => "<form123@mailjet.com>",
          "From" => "Jane <jane@example.com>",
          "To" => "support@acme.inbound.kiket.dev",
          "Subject" => "Form test"
        })

        payload = {
          "event" => "external.webhook.inbound_email",
          "action" => "inbound_email",
          "external_webhook" => {
            "body" => form_body,
            "headers" => {},
            "content_type" => "application/x-www-form-urlencoded",
            "method" => "POST",
            "query_params" => {}
          },
          "received_at" => Time.now.iso8601,
          "authentication" => {
            "runtime_token" => "test_runtime_token_abc123"
          },
          "api" => {
            "base_url" => "https://kiket.test"
          },
          "secrets" => {}
        }

        make_webhook_request(payload)

        expect(WebMock).to have_requested(:post, "https://kiket.test/api/v1/ext/inbound_emails")
          .with { |req|
            body = JSON.parse(req.body)
            body["inbound_email"]["message_id"] == "<form123@mailjet.com>" &&
              body["inbound_email"]["from_email"] == "jane@example.com"
          }
      end
    end
  end

  describe "GET /health" do
    it "returns healthy status" do
      get "/health"
      expect(last_response.status).to eq(200)

      body = JSON.parse(last_response.body)
      expect(body["status"]).to eq("ok")
    end

    it "lists registered events" do
      get "/health"
      body = JSON.parse(last_response.body)
      expect(body["registered_events"]).to eq([ "external.webhook.inbound_email" ])
    end
  end
end
