# frozen_string_literal: true

require "kiket_sdk"
require "rackup"
require "json"
require "logger"
require "mailjet"

# Mailjet Inbound Email Extension
# Receives emails from Mailjet Parse API via External Webhook Routing and creates issues/comments in Kiket
#
# Features:
# - Automatic Mailjet Parse API setup via customer's Mailjet credentials
# - Processes inbound emails and creates issues/comments in Kiket
# - Supports sender policy enforcement
#
# Architecture (External Webhook Routing):
# 1. Mailjet sends webhooks to Kiket's external webhook URL: /webhooks/ext/:webhook_token/inbound_email
# 2. Kiket forwards to this extension with a runtime token (external.webhook.inbound_email event)
# 3. Extension processes the payload and calls Kiket API using the runtime token
class MailjetInboundExtension
  class MailjetAPIError < StandardError; end

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
    @sdk.register("external.webhook.inbound_email", version: "v1", required_scopes: %w[issues:write]) do |payload, context|
      process_mailjet_webhook(payload, context)
    end

    # Setup action: Connect to Mailjet Parse API
    @sdk.register("mailjet.connectParseApi", version: "v1", required_scopes: %w[configuration:write]) do |payload, context|
      connect_parse_api(payload, context)
    end
  end

  # ============================================================================
  # Setup Action: Connect to Mailjet Parse API
  # ============================================================================

  def connect_parse_api(payload, context)
    # Get Mailjet credentials from secrets
    api_key = context[:secret].call("MAILJET_API_KEY")
    secret_key = context[:secret].call("MAILJET_SECRET_KEY")

    if api_key.nil? || api_key.empty? || secret_key.nil? || secret_key.empty?
      return { success: false, error: "Missing Mailjet API credentials. Please configure MAILJET_API_KEY and MAILJET_SECRET_KEY in secrets." }
    end

    # Configure Mailjet client
    configure_mailjet(api_key, secret_key)

    # Get the webhook URL from Kiket
    webhook_info = context[:client].get("/api/v1/ext/webhook_url", { action_name: "inbound_email" })
    webhook_url = webhook_info["webhook_url"]

    if webhook_url.nil? || webhook_url.empty?
      return { success: false, error: "Could not retrieve webhook URL from Kiket" }
    end

    # Determine the inbound email address
    # Use organization subdomain or project key for uniqueness
    org_subdomain = payload.dig("organization", "subdomain") || payload.dig("project", "key")&.downcase
    inbound_email = if org_subdomain && !org_subdomain.empty?
      "#{org_subdomain}@inbound.kiket.dev"
    else
      # Fall back to Mailjet's auto-generated address
      nil
    end

    # Check for existing parse routes
    existing_route = find_existing_route(webhook_url)

    if existing_route
      # Update existing route if URL changed
      @logger.info "Found existing Mailjet parse route: #{existing_route.email}"
      return {
        success: true,
        message: "Parse route already configured",
        email: existing_route.email,
        route_id: existing_route.id
      }
    end

    # Create new parse route
    route = create_parse_route(webhook_url, inbound_email)

    # Store the inbound email in configuration for reference
    if route.email
      context[:client].patch("/api/v1/ext/configuration", {
        configuration: { mailjet_inbound_email: route.email }
      })
    end

    context[:endpoints].log_event("mailjet.parse_route.created", {
      email: route.email,
      route_id: route.id
    })

    {
      success: true,
      message: "Successfully configured Mailjet Parse API",
      email: route.email,
      route_id: route.id
    }
  rescue Mailjet::ApiError => e
    @logger.error "Mailjet API error: #{e.message}"
    error_message = parse_mailjet_error(e)
    { success: false, error: "Mailjet API error: #{error_message}" }
  rescue StandardError => e
    @logger.error "Error connecting to Mailjet: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    { success: false, error: e.message }
  end

  def configure_mailjet(api_key, secret_key)
    Mailjet.configure do |config|
      config.api_key = api_key
      config.secret_key = secret_key
      config.api_version = "v3"
    end
  end

  def find_existing_route(webhook_url)
    routes = Mailjet::Parseroute.all
    # Find route that points to our webhook URL (or contains our webhook token)
    webhook_token = webhook_url.split("/webhooks/ext/").last&.split("/")&.first
    routes.find do |route|
      route.url == webhook_url || (webhook_token && route.url&.include?(webhook_token))
    end
  rescue Mailjet::ApiError => e
    @logger.warn "Could not list existing parse routes: #{e.message}"
    nil
  end

  def create_parse_route(webhook_url, inbound_email = nil)
    params = { url: webhook_url }
    params[:email] = inbound_email if inbound_email

    Mailjet::Parseroute.create(params)
  end

  def parse_mailjet_error(error)
    # Try to extract meaningful error message from Mailjet API response
    if error.message.include?("401")
      "Invalid API credentials. Please check your MAILJET_API_KEY and MAILJET_SECRET_KEY."
    elsif error.message.include?("403")
      "Access denied. Your Mailjet plan may not include Parse API (requires Crystal plan or above)."
    elsif error.message.include?("already exists")
      "A parse route with this configuration already exists."
    else
      error.message
    end
  end

  # ============================================================================
  # Inbound Email Processing
  # ============================================================================

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
