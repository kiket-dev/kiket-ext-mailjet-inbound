# frozen_string_literal: true

require "kiket_sdk"
require 'rackup'
require "json"
require "logger"

# Mailjet Inbound Email Extension
# Receives emails from Mailjet Parse API via External Webhook Routing and creates issues/comments in Kiket
#
# New architecture (External Webhook Routing):
# 1. Mailjet sends webhooks to Kiket's external webhook URL: /webhooks/ext/:webhook_token/inbound_email
# 2. Kiket forwards to this extension with a runtime token (external.webhook.inbound_email event)
# 3. Extension processes the payload and calls Kiket API using the runtime token
#
# This eliminates the need for Extension API Keys - runtime tokens provide per-invocation auth.
class MailjetInboundExtension
  def initialize
    @sdk = KiketSDK.new
    @logger = Logger.new($stdout)
    setup_handlers
  end

  def app
    @sdk
  end

  private

  def setup_handlers
    # Handle external webhook events from Mailjet (routed through Kiket)
    # Event type: external.webhook.inbound_email
    @sdk.register("external.webhook.inbound_email", version: "v1", required_scopes: %w[issues:write]) do |payload, context|
      process_mailjet_webhook(payload, context)
    end
  end

  def process_mailjet_webhook(payload, context)
    # Extract the original Mailjet webhook data from external_webhook envelope
    external_webhook = payload["external_webhook"] || {}
    body = external_webhook["body"] || ""
    headers = external_webhook["headers"] || {}

    # Verify Mailjet webhook token if configured
    expected_token = context[:secret].call("MAILJET_WEBHOOK_TOKEN")
    if expected_token && !expected_token.empty?
      received_token = headers["X-Mailjet-Token"] || payload.dig("external_webhook", "query_params", "token")
      unless received_token && secure_compare(received_token, expected_token)
        @logger.warn "Mailjet webhook token verification failed"
        return { ok: false, error: "Unauthorized" }
      end
    end

    # Parse the Mailjet payload
    mailjet_payload = parse_mailjet_body(body, external_webhook["content_type"])

    # Normalize to standard format
    normalized = normalize_payload(mailjet_payload)

    # Submit to Kiket API using the runtime token (via context[:client])
    result = context[:client].post("/api/v1/ext/inbound_emails", { inbound_email: normalized })

    context[:endpoints].log_event("mailjet.inbound_email.processed", {
      message_id: normalized[:message_id],
      from: normalized[:from_email],
      to: normalized[:to_email]
    })

    { ok: true, id: result["id"] }
  rescue JSON::ParserError => e
    @logger.error "Invalid JSON from Mailjet: #{e.message}"
    { ok: false, error: "Invalid JSON" }
  rescue StandardError => e
    @logger.error "Error processing Mailjet webhook: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    { ok: false, error: e.message }
  end

  def parse_mailjet_body(body, content_type)
    return {} if body.nil? || body.empty?

    if content_type&.include?("application/json")
      JSON.parse(body)
    elsif content_type&.include?("application/x-www-form-urlencoded")
      # Parse form-urlencoded data
      URI.decode_www_form(body).to_h
    else
      # Try JSON first, fall back to treating as-is
      begin
        JSON.parse(body)
      rescue JSON::ParserError
        { "Text-part" => body }
      end
    end
  end

  def normalize_payload(mailjet_payload)
    {
      message_id: mailjet_payload["MessageID"] || mailjet_payload["Message-Id"],
      in_reply_to: mailjet_payload["InReplyTo"] || mailjet_payload["In-Reply-To"],
      references: parse_references(mailjet_payload["References"]),
      from_email: extract_email(mailjet_payload["From"]),
      from_name: extract_name(mailjet_payload["From"]),
      to_email: extract_email(mailjet_payload["To"]),
      cc_emails: parse_email_list(mailjet_payload["Cc"]),
      subject: mailjet_payload["Subject"],
      text_body: mailjet_payload["Text-part"] || mailjet_payload["TextPart"],
      html_body: mailjet_payload["Html-part"] || mailjet_payload["HtmlPart"],
      headers: parse_headers(mailjet_payload["Headers"]),
      attachments: parse_attachments(mailjet_payload["Attachments"]),
      raw_payload: mailjet_payload.to_json
    }
  end

  def extract_email(address_string)
    return nil if address_string.nil?

    # Parse "Name <email@example.com>" or "email@example.com"
    if (match = address_string.match(/<([^>]+)>/))
      match[1]
    else
      address_string.strip
    end
  end

  def extract_name(address_string)
    return nil if address_string.nil?

    # Parse "Name <email@example.com>"
    if (match = address_string.match(/^([^<]+)\s*</))
      match[1].strip.gsub(/^["']|["']$/, "")
    end
  end

  def parse_email_list(addresses)
    return [] if addresses.nil?

    addresses.split(",").map { |addr| extract_email(addr.strip) }.compact
  end

  def parse_references(references)
    return [] if references.nil?

    references.split(/\s+/).map(&:strip).reject(&:empty?)
  end

  def parse_headers(headers_data)
    return {} if headers_data.nil?

    case headers_data
    when String
      JSON.parse(headers_data)
    when Hash
      headers_data
    else
      {}
    end
  rescue JSON::ParserError
    {}
  end

  def parse_attachments(attachments_data)
    return [] if attachments_data.nil?

    case attachments_data
    when Array
      attachments_data.map do |att|
        {
          filename: att["Filename"] || att["filename"],
          content_type: att["ContentType"] || att["content_type"],
          size: att["Size"] || att["size"],
          content_id: att["ContentID"] || att["content_id"]
        }
      end
    else
      []
    end
  end

  def secure_compare(a, b)
    return false unless a.bytesize == b.bytesize

    a.bytes.zip(b.bytes).reduce(0) { |sum, (x, y)| sum | (x ^ y) }.zero?
  end
end

# Run the extension
if __FILE__ == $PROGRAM_NAME
  extension = MailjetInboundExtension.new

  Rackup::Handler.get(:puma).run(
    extension.app,
    Host: ENV.fetch("HOST", "0.0.0.0"),
    Port: ENV.fetch("PORT", 8080).to_i,
    Threads: "0:16"
  )
end
