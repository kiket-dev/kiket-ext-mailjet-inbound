# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MailjetInboundExtension do
  let(:app) { described_class.new.app }

  # Build external webhook payload as Kiket would send it
  def build_webhook_payload(mailjet_payload, headers: {}, content_type: 'application/json')
    {
      'event' => 'external.webhook.inbound_email',
      'action' => 'inbound_email',
      'external_webhook' => {
        'body' => mailjet_payload.to_json,
        'headers' => headers,
        'content_type' => content_type,
        'method' => 'POST',
        'query_params' => {}
      },
      'received_at' => Time.now.iso8601,
      'authentication' => {
        'runtime_token' => 'test_runtime_token_abc123'
      },
      'api' => {
        'base_url' => 'https://kiket.test'
      },
      'secrets' => {}
    }
  end

  def build_setup_payload(secrets: {}, organization: {}, project: {})
    {
      'event' => 'mailjet.connectParseApi',
      'action' => 'connectParseApi',
      'received_at' => Time.now.iso8601,
      'authentication' => {
        'runtime_token' => 'test_runtime_token_abc123'
      },
      'api' => {
        'base_url' => 'https://kiket.test'
      },
      'secrets' => secrets,
      'organization' => organization,
      'project' => project
    }
  end

  def make_webhook_request(payload, headers = {})
    post '/v/v1/webhooks/external.webhook.inbound_email', payload.to_json, {
      'CONTENT_TYPE' => 'application/json'
    }.merge(headers)
  end

  def make_setup_request(payload, headers = {})
    post '/v/v1/webhooks/mailjet.connectParseApi', payload.to_json, {
      'CONTENT_TYPE' => 'application/json'
    }.merge(headers)
  end

  before do
    # Stub JWT verification
    allow(KiketSDK::Auth).to receive(:verify_runtime_token).and_return({
                                                                         'exp' => (Time.now + 3600).to_i,
                                                                         'scopes' => ['*'],
                                                                         'org_id' => 1,
                                                                         'ext_id' => 'dev.kiket.ext.mailjet-inbound',
                                                                         'proj_id' => 1
                                                                       })

    # Stub API calls with proper Content-Type for Faraday JSON middleware
    stub_request(:post, 'https://kiket.test/api/v1/ext/inbound_emails')
      .to_return(status: 200, body: { id: 123,
                                      status: 'pending' }.to_json, headers: { 'Content-Type' => 'application/json' })

    # SDK calls /extensions/:extension_id/events for log_event
    # Extension ID comes from manifest (dev.kiket.ext.mailjet-inbound)
    stub_request(:post, %r{https://kiket.test/extensions/.*/events})
      .to_return(status: 200, body: { ok: true }.to_json, headers: { 'Content-Type' => 'application/json' })

    # SDK telemetry endpoint
    stub_request(:post, 'https://kiket.test/api/v1/ext/telemetry')
      .to_return(status: 200, body: { ok: true }.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  describe 'POST /v/v1/webhooks/external.webhook.inbound_email' do
    let(:mailjet_payload) do
      {
        'MessageID' => '<abc123@mailjet.com>',
        'From' => 'John Doe <john@example.com>',
        'To' => 'support@acme.inbound.kiket.dev',
        'Subject' => 'Help with my order',
        'Text-part' => 'I need help with order #12345',
        'Html-part' => '<p>I need help with order #12345</p>',
        'Headers' => { 'X-Custom' => 'value' }.to_json
      }
    end

    it 'accepts valid external webhook payloads' do
      payload = build_webhook_payload(mailjet_payload)
      make_webhook_request(payload)
      expect(last_response.status).to eq(200)
    end

    it 'returns the created inbound email id' do
      payload = build_webhook_payload(mailjet_payload)
      make_webhook_request(payload)
      body = JSON.parse(last_response.body)
      expect(body['id']).to eq(123)
    end

    it 'normalizes the payload correctly' do
      payload = build_webhook_payload(mailjet_payload)
      make_webhook_request(payload)

      expect(WebMock).to(have_requested(:post, 'https://kiket.test/api/v1/ext/inbound_emails')
        .with do |req|
          body = JSON.parse(req.body)
          email = body['inbound_email']
          email['message_id'] == '<abc123@mailjet.com>' &&
            email['from_email'] == 'john@example.com' &&
            email['from_name'] == 'John Doe' &&
            email['to_email'] == 'support@acme.inbound.kiket.dev' &&
            email['subject'] == 'Help with my order'
        end)
    end

    it 'uses runtime token for API calls' do
      payload = build_webhook_payload(mailjet_payload)
      make_webhook_request(payload)

      expect(WebMock).to have_requested(:post, 'https://kiket.test/api/v1/ext/inbound_emails')
        .with(headers: { 'X-Kiket-Runtime-Token' => 'test_runtime_token_abc123' })
    end

    context 'with webhook token verification' do
      before do
        # Simulate MAILJET_WEBHOOK_TOKEN secret being present
        allow_any_instance_of(described_class).to receive(:secure_compare) do |_instance, a, b|
          a == b
        end
      end

      it 'accepts requests with valid token in headers' do
        payload = build_webhook_payload(
          mailjet_payload,
          headers: { 'X-Mailjet-Token' => 'secret_token' }
        )
        payload['secrets'] = { 'MAILJET_WEBHOOK_TOKEN' => 'secret_token' }

        make_webhook_request(payload)
        expect(last_response.status).to eq(200)
      end

      it 'rejects requests with invalid token' do
        payload = build_webhook_payload(
          mailjet_payload,
          headers: { 'X-Mailjet-Token' => 'wrong_token' }
        )
        payload['secrets'] = { 'MAILJET_WEBHOOK_TOKEN' => 'secret_token' }

        make_webhook_request(payload)
        body = JSON.parse(last_response.body)
        expect(body['ok']).to be(false)
        expect(body['error']).to eq('Unauthorized')
      end

      it 'accepts requests without token when secret not configured' do
        payload = build_webhook_payload(mailjet_payload)
        # No secrets in payload, no ENV var

        make_webhook_request(payload)
        expect(last_response.status).to eq(200)
      end
    end

    context 'with reply email' do
      let(:reply_payload) do
        mailjet_payload.merge(
          'InReplyTo' => '<original123@mailjet.com>',
          'Subject' => 'Re: Help with my order'
        )
      end

      it 'includes in_reply_to in normalized payload' do
        payload = build_webhook_payload(reply_payload)
        make_webhook_request(payload)

        expect(WebMock).to(have_requested(:post, 'https://kiket.test/api/v1/ext/inbound_emails')
          .with do |req|
            body = JSON.parse(req.body)
            body['inbound_email']['in_reply_to'] == '<original123@mailjet.com>'
          end)
      end
    end

    context 'with form-urlencoded content' do
      it 'handles form-urlencoded Mailjet payloads' do
        form_body = URI.encode_www_form({
                                          'MessageID' => '<form123@mailjet.com>',
                                          'From' => 'Jane <jane@example.com>',
                                          'To' => 'support@acme.inbound.kiket.dev',
                                          'Subject' => 'Form test'
                                        })

        payload = {
          'event' => 'external.webhook.inbound_email',
          'action' => 'inbound_email',
          'external_webhook' => {
            'body' => form_body,
            'headers' => {},
            'content_type' => 'application/x-www-form-urlencoded',
            'method' => 'POST',
            'query_params' => {}
          },
          'received_at' => Time.now.iso8601,
          'authentication' => {
            'runtime_token' => 'test_runtime_token_abc123'
          },
          'api' => {
            'base_url' => 'https://kiket.test'
          },
          'secrets' => {}
        }

        make_webhook_request(payload)

        expect(WebMock).to(have_requested(:post, 'https://kiket.test/api/v1/ext/inbound_emails')
          .with do |req|
            body = JSON.parse(req.body)
            body['inbound_email']['message_id'] == '<form123@mailjet.com>' &&
              body['inbound_email']['from_email'] == 'jane@example.com'
          end)
      end
    end
  end

  describe 'POST /v/v1/webhooks/mailjet.connectParseApi' do
    let(:webhook_url) { 'https://kiket.dev/webhooks/ext/abc123token/inbound_email' }
    let(:parseroute_response) do
      double('Parseroute', id: 12_345, email: 'acme@parse-in1.mailjet.com', url: webhook_url)
    end

    before do
      # Stub Kiket API for webhook URL
      stub_request(:get, 'https://kiket.test/api/v1/ext/webhook_url?action_name=inbound_email')
        .to_return(status: 200, body: {
          webhook_url: webhook_url,
          webhook_token: 'abc123token'
        }.to_json, headers: { 'Content-Type' => 'application/json' })

      # Stub Kiket API for configuration update
      stub_request(:patch, 'https://kiket.test/api/v1/ext/configuration')
        .to_return(status: 200, body: { ok: true }.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    context 'with valid credentials' do
      let(:secrets) do
        {
          'MAILJET_API_KEY' => 'test_api_key',
          'MAILJET_SECRET_KEY' => 'test_secret_key'
        }
      end

      before do
        # Stub Mailjet API
        allow(Mailjet::Parseroute).to receive_messages(all: [], create: parseroute_response)
      end

      it 'creates a new parse route' do
        payload = build_setup_payload(
          secrets: secrets,
          organization: { 'subdomain' => 'acme' }
        )

        make_setup_request(payload)

        expect(last_response.status).to eq(200)
        body = JSON.parse(last_response.body)
        expect(body['success']).to be(true)
        expect(body['email']).to eq('acme@parse-in1.mailjet.com')
        expect(body['route_id']).to eq(12_345)
      end

      it 'configures Mailjet with provided credentials' do
        payload = build_setup_payload(secrets: secrets)

        expect(Mailjet).to receive(:configure).and_yield(double.as_null_object)

        make_setup_request(payload)
      end

      it 'uses organization subdomain for inbound email' do
        payload = build_setup_payload(
          secrets: secrets,
          organization: { 'subdomain' => 'acme' }
        )

        expect(Mailjet::Parseroute).to receive(:create)
          .with(hash_including(email: 'acme@inbound.kiket.dev'))
          .and_return(parseroute_response)

        make_setup_request(payload)
      end

      it 'falls back to project key for inbound email' do
        payload = build_setup_payload(
          secrets: secrets,
          organization: {},
          project: { 'key' => 'PROJ' }
        )

        expect(Mailjet::Parseroute).to receive(:create)
          .with(hash_including(email: 'proj@inbound.kiket.dev'))
          .and_return(parseroute_response)

        make_setup_request(payload)
      end

      it 'stores inbound email in configuration' do
        payload = build_setup_payload(secrets: secrets)

        make_setup_request(payload)

        expect(WebMock).to(have_requested(:patch, 'https://kiket.test/api/v1/ext/configuration')
          .with do |req|
            body = JSON.parse(req.body)
            body['configuration']['mailjet_inbound_email'] == 'acme@parse-in1.mailjet.com'
          end)
      end

      it 'logs parse route creation event' do
        payload = build_setup_payload(secrets: secrets)

        make_setup_request(payload)

        # SDK calls /extensions/:extension_id/events for log_event
        expect(WebMock).to have_requested(:post, %r{https://kiket.test/extensions/.*/events})
      end
    end

    context 'when parse route already exists' do
      let(:secrets) do
        {
          'MAILJET_API_KEY' => 'test_api_key',
          'MAILJET_SECRET_KEY' => 'test_secret_key'
        }
      end

      let(:existing_route) do
        double('Parseroute', id: 99_999, email: 'existing@parse-in1.mailjet.com', url: webhook_url)
      end

      before do
        allow(Mailjet::Parseroute).to receive(:all).and_return([existing_route])
      end

      it 'returns existing route without creating new one' do
        payload = build_setup_payload(secrets: secrets)

        expect(Mailjet::Parseroute).not_to receive(:create)

        make_setup_request(payload)

        body = JSON.parse(last_response.body)
        expect(body['success']).to be(true)
        expect(body['message']).to eq('Parse route already configured')
        expect(body['route_id']).to eq(99_999)
      end
    end

    context 'with missing credentials' do
      it 'returns error when API key is missing' do
        payload = build_setup_payload(secrets: { 'MAILJET_SECRET_KEY' => 'secret' })

        make_setup_request(payload)

        body = JSON.parse(last_response.body)
        expect(body['success']).to be(false)
        expect(body['error']).to include('Missing Mailjet API credentials')
      end

      it 'returns error when secret key is missing' do
        payload = build_setup_payload(secrets: { 'MAILJET_API_KEY' => 'key' })

        make_setup_request(payload)

        body = JSON.parse(last_response.body)
        expect(body['success']).to be(false)
        expect(body['error']).to include('Missing Mailjet API credentials')
      end

      it 'returns error when both credentials are missing' do
        payload = build_setup_payload(secrets: {})

        make_setup_request(payload)

        body = JSON.parse(last_response.body)
        expect(body['success']).to be(false)
        expect(body['error']).to include('Missing Mailjet API credentials')
      end
    end

    context 'with Mailjet API errors' do
      let(:secrets) do
        {
          'MAILJET_API_KEY' => 'invalid_key',
          'MAILJET_SECRET_KEY' => 'invalid_secret'
        }
      end

      it 'handles 401 unauthorized error' do
        allow(Mailjet::Parseroute).to receive(:all)
          .and_raise(Mailjet::ApiError.new(401, 'Unauthorized', nil, 'https://api.mailjet.com', {}))

        payload = build_setup_payload(secrets: secrets)
        make_setup_request(payload)

        body = JSON.parse(last_response.body)
        expect(body['success']).to be(false)
        expect(body['error']).to include('Invalid API credentials')
      end

      it 'handles 403 forbidden error' do
        allow(Mailjet::Parseroute).to receive(:all)
          .and_raise(Mailjet::ApiError.new(403, 'Forbidden', nil, 'https://api.mailjet.com', {}))

        payload = build_setup_payload(secrets: secrets)
        make_setup_request(payload)

        body = JSON.parse(last_response.body)
        expect(body['success']).to be(false)
        expect(body['error']).to include('Access denied')
      end

      it 'handles generic Mailjet errors' do
        # Generic errors (non-auth) are caught in find_existing_route, so code proceeds to create
        # We need to stub create as well to simulate the error
        allow(Mailjet::Parseroute).to receive(:all)
          .and_raise(Mailjet::ApiError.new(500, 'Something went wrong', nil, 'https://api.mailjet.com', {}))
        allow(Mailjet::Parseroute).to receive(:create)
          .and_raise(Mailjet::ApiError.new(500, 'Something went wrong', nil, 'https://api.mailjet.com', {}))

        payload = build_setup_payload(secrets: secrets)
        make_setup_request(payload)

        body = JSON.parse(last_response.body)
        expect(body['success']).to be(false)
        expect(body['error']).to include('Mailjet API error')
      end
    end

    context 'when webhook URL cannot be retrieved' do
      let(:secrets) do
        {
          'MAILJET_API_KEY' => 'test_api_key',
          'MAILJET_SECRET_KEY' => 'test_secret_key'
        }
      end

      before do
        stub_request(:get, 'https://kiket.test/api/v1/ext/webhook_url?action_name=inbound_email')
          .to_return(status: 200, body: { webhook_url: nil }.to_json, headers: { 'Content-Type' => 'application/json' })
      end

      it 'returns error' do
        payload = build_setup_payload(secrets: secrets)
        make_setup_request(payload)

        body = JSON.parse(last_response.body)
        expect(body['success']).to be(false)
        expect(body['error']).to include('Could not retrieve webhook URL')
      end
    end
  end

  describe 'GET /health' do
    it 'returns healthy status' do
      get '/health'
      expect(last_response.status).to eq(200)

      body = JSON.parse(last_response.body)
      expect(body['status']).to eq('ok')
    end

    it 'lists registered events' do
      get '/health'
      body = JSON.parse(last_response.body)
      expect(body['registered_events']).to contain_exactly(
        'external.webhook.inbound_email',
        'mailjet.connectParseApi'
      )
    end
  end
end
