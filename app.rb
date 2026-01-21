# frozen_string_literal: true

require 'kiket_sdk'
require 'rackup'
require 'json'
require 'twilio-ruby'
require 'phonelib'
require 'logger'

# Twilio Notification Extension
# Handles sending SMS, MMS, and voice notifications via Twilio
class TwilioNotificationExtension
  REQUIRED_NOTIFY_SCOPES = %w[notifications:send].freeze
  REQUIRED_VALIDATE_SCOPES = %w[notifications:read].freeze
  REQUIRED_PREFERENCES_SCOPES = %w[users:write].freeze

  class OptInError < StandardError; end
  class RateLimitError < StandardError; end

  def initialize
    @sdk = KiketSDK.new
    @logger = Logger.new($stdout)
    @opt_in_storage = {}
    @rate_limit_state = { count: 0, reset_at: Time.now + 60 }

    setup_handlers
  end

  def app
    @sdk
  end

  private

  def setup_handlers
    # Send SMS notification
    @sdk.register('twilio.sms.send', version: 'v1', required_scopes: REQUIRED_NOTIFY_SCOPES) do |payload, context|
      handle_send_sms(payload, context)
    end

    # Send voice notification
    @sdk.register('twilio.voice.send', version: 'v1', required_scopes: REQUIRED_NOTIFY_SCOPES) do |payload, context|
      handle_send_voice(payload, context)
    end

    # Send MMS notification
    @sdk.register('twilio.mms.send', version: 'v1', required_scopes: REQUIRED_NOTIFY_SCOPES) do |payload, context|
      handle_send_mms(payload, context)
    end

    # Check opt-in status
    @sdk.register('twilio.opt_in.check', version: 'v1', required_scopes: REQUIRED_VALIDATE_SCOPES) do |payload, context|
      handle_check_opt_in(payload, context)
    end

    # Update opt-in status
    @sdk.register('twilio.opt_in.update', version: 'v1', required_scopes: REQUIRED_PREFERENCES_SCOPES) do |payload, context|
      handle_update_opt_in(payload, context)
    end

    # Validate phone number
    @sdk.register('twilio.validate', version: 'v1', required_scopes: REQUIRED_VALIDATE_SCOPES) do |payload, context|
      handle_validate_phone(payload, context)
    end

    # External webhook endpoint for Twilio status callbacks (via External Webhook Routing)
    # Receives: external.webhook.status_callback events forwarded by Kiket
    @sdk.register('external.webhook.status_callback', version: 'v1', required_scopes: []) do |payload, context|
      handle_status_webhook(payload, context)
    end
  end

  def handle_send_sms(payload, context)
    validate_sms_request!(payload)
    check_rate_limit!

    to_number = normalize_phone_number(payload['to'], context)

    raise OptInError, "Recipient #{to_number} has not opted in for SMS notifications" if opt_in_required?(context) && !check_opt_in(to_number)

    client = twilio_client(context)
    message = client.messages.create(
      from: twilio_phone_number(context),
      to: to_number,
      body: payload['message'],
      status_callback: status_callback_url(context)
    )

    increment_rate_limit!

    context[:endpoints].log_event('twilio.sms.sent', {
                                    to: to_number,
                                    message_sid: message.sid,
                                    org_id: context[:auth][:org_id]
                                  })

    {
      success: true,
      message_sid: message.sid,
      to: message.to,
      status: message.status,
      sent_at: Time.now.utc.iso8601
    }
  rescue ArgumentError, OptInError, RateLimitError => e
    @logger.error "Validation error: #{e.message}"
    { success: false, error: e.message }
  rescue Twilio::REST::RestError => e
    @logger.error "Twilio API error: #{e.message}"
    { success: false, error: "Twilio API error: #{e.message}", error_code: e.code }
  rescue StandardError => e
    @logger.error "Unexpected error: #{e.message}\n#{e.backtrace.join("\n")}"
    { success: false, error: 'Internal server error' }
  end

  def handle_send_voice(payload, context)
    validate_voice_request!(payload)
    check_rate_limit!

    to_number = normalize_phone_number(payload['to'], context)

    raise OptInError, "Recipient #{to_number} has not opted in for voice notifications" if opt_in_required?(context) && !check_opt_in(to_number)

    twiml = generate_voice_twiml(payload['message'])
    client = twilio_client(context)
    call = client.calls.create(
      from: twilio_phone_number(context),
      to: to_number,
      twiml: twiml,
      status_callback: status_callback_url(context),
      status_callback_event: %w[initiated ringing answered completed]
    )

    increment_rate_limit!

    context[:endpoints].log_event('twilio.voice.sent', {
                                    to: to_number,
                                    call_sid: call.sid,
                                    org_id: context[:auth][:org_id]
                                  })

    {
      success: true,
      call_sid: call.sid,
      to: call.to,
      status: call.status,
      initiated_at: Time.now.utc.iso8601
    }
  rescue ArgumentError, OptInError, RateLimitError => e
    @logger.error "Validation error: #{e.message}"
    { success: false, error: e.message }
  rescue Twilio::REST::RestError => e
    @logger.error "Twilio API error: #{e.message}"
    { success: false, error: "Twilio API error: #{e.message}", error_code: e.code }
  rescue StandardError => e
    @logger.error "Unexpected error: #{e.message}\n#{e.backtrace.join("\n")}"
    { success: false, error: 'Internal server error' }
  end

  def handle_send_mms(payload, context)
    validate_mms_request!(payload)
    check_rate_limit!

    to_number = normalize_phone_number(payload['to'], context)

    raise OptInError, "Recipient #{to_number} has not opted in for MMS notifications" if opt_in_required?(context) && !check_opt_in(to_number)

    client = twilio_client(context)
    message = client.messages.create(
      from: twilio_phone_number(context),
      to: to_number,
      body: payload['message'],
      media_url: payload['media_urls'],
      status_callback: status_callback_url(context)
    )

    increment_rate_limit!

    context[:endpoints].log_event('twilio.mms.sent', {
                                    to: to_number,
                                    message_sid: message.sid,
                                    media_count: message.num_media.to_i,
                                    org_id: context[:auth][:org_id]
                                  })

    {
      success: true,
      message_sid: message.sid,
      to: message.to,
      status: message.status,
      media_count: message.num_media.to_i,
      sent_at: Time.now.utc.iso8601
    }
  rescue ArgumentError, OptInError, RateLimitError => e
    @logger.error "Validation error: #{e.message}"
    { success: false, error: e.message }
  rescue Twilio::REST::RestError => e
    @logger.error "Twilio API error: #{e.message}"
    { success: false, error: "Twilio API error: #{e.message}", error_code: e.code }
  rescue StandardError => e
    @logger.error "Unexpected error: #{e.message}\n#{e.backtrace.join("\n")}"
    { success: false, error: 'Internal server error' }
  end

  def handle_check_opt_in(payload, context)
    raise ArgumentError, 'Missing required field: phone_number' unless payload['phone_number']

    phone_number = normalize_phone_number(payload['phone_number'], context)
    opted_in = check_opt_in(phone_number)

    {
      success: true,
      phone_number: phone_number,
      opted_in: opted_in,
      checked_at: Time.now.utc.iso8601
    }
  rescue ArgumentError => e
    { success: false, error: e.message }
  end

  def handle_update_opt_in(payload, context)
    raise ArgumentError, 'Missing required field: phone_number' unless payload['phone_number']
    raise ArgumentError, 'Missing required field: opted_in' if payload['opted_in'].nil?

    phone_number = normalize_phone_number(payload['phone_number'], context)
    opted_in = payload['opted_in']

    update_opt_in(phone_number, opted_in)

    {
      success: true,
      phone_number: phone_number,
      opted_in: opted_in,
      updated_at: Time.now.utc.iso8601
    }
  rescue ArgumentError => e
    { success: false, error: e.message }
  end

  def handle_validate_phone(payload, context)
    raise ArgumentError, 'Missing required field: phone_number' unless payload['phone_number']

    default_country = context[:secret].call('DEFAULT_COUNTRY_CODE') || 'US'
    phone = Phonelib.parse(payload['phone_number'], default_country)

    {
      success: true,
      phone_number: payload['phone_number'],
      valid: phone.valid?,
      e164_format: phone.e164,
      country: phone.country,
      national_format: phone.national,
      type: phone.type,
      possible: phone.possible?
    }
  rescue ArgumentError => e
    { success: false, error: e.message }
  end

  def handle_status_webhook(payload, context)
    # Extract the original Twilio webhook data from external_webhook envelope
    external_webhook = payload['external_webhook'] || {}
    body = external_webhook['body'] || {}
    headers = external_webhook['headers'] || {}
    original_url = external_webhook['original_url']

    # Parse body if it's a string (form-urlencoded from Twilio)
    twilio_params = parse_twilio_body(body, external_webhook['content_type'])

    # Verify Twilio signature if auth token is available
    auth_token = context[:secret].call('TWILIO_AUTH_TOKEN')
    if auth_token && original_url
      signature = headers['X-Twilio-Signature'] || headers['x-twilio-signature']
      unless verify_twilio_signature(auth_token, original_url, twilio_params, signature)
        @logger.warn 'Twilio signature verification failed'
        return { success: false, error: 'Invalid signature' }
      end
    end

    @logger.info "Twilio status callback: MessageSid=#{twilio_params['MessageSid']}, Status=#{twilio_params['MessageStatus'] || twilio_params['CallStatus']}"

    context[:endpoints].log_event('twilio.status.received', {
                                    message_sid: twilio_params['MessageSid'] || twilio_params['CallSid'],
                                    status: twilio_params['MessageStatus'] || twilio_params['CallStatus'],
                                    error_code: twilio_params['ErrorCode'],
                                    org_id: context[:auth]&.dig(:org_id)
                                  })

    { success: true, received_at: Time.now.utc.iso8601 }
  rescue StandardError => e
    @logger.error "Error processing Twilio status callback: #{e.message}"
    { success: false, error: e.message }
  end

  def parse_twilio_body(body, content_type)
    return body if body.is_a?(Hash)
    return {} if body.nil? || body.empty?

    if content_type&.include?('application/x-www-form-urlencoded')
      URI.decode_www_form(body).to_h
    elsif content_type&.include?('application/json')
      JSON.parse(body)
    else
      # Try form-urlencoded first (Twilio's default), fall back to JSON
      begin
        URI.decode_www_form(body).to_h
      rescue ArgumentError
        begin
          JSON.parse(body)
        rescue StandardError
          {}
        end
      end
    end
  end

  def verify_twilio_signature(auth_token, url, params, signature)
    return false if signature.nil? || signature.empty?

    validator = Twilio::Security::RequestValidator.new(auth_token)
    validator.validate(url, params, signature)
  end

  # Helper methods

  def twilio_client(context)
    account_sid = context[:secret].call('TWILIO_ACCOUNT_SID')
    auth_token = context[:secret].call('TWILIO_AUTH_TOKEN')

    raise ArgumentError, 'Missing Twilio credentials' unless account_sid && auth_token

    Twilio::REST::Client.new(account_sid, auth_token)
  end

  def twilio_phone_number(context)
    context[:secret].call('TWILIO_PHONE_NUMBER') ||
      raise(ArgumentError, 'Missing TWILIO_PHONE_NUMBER')
  end

  def default_country_code(context)
    context[:secret].call('DEFAULT_COUNTRY_CODE') || 'US'
  end

  def opt_in_required?(context)
    (context[:secret].call('REQUIRE_OPT_IN') || 'true') == 'true'
  end

  def status_callback_url(context)
    return nil unless (context[:secret].call('ENABLE_DELIVERY_TRACKING') || 'true') == 'true'

    # Use External Webhook Routing URL (provided by Kiket)
    # Format: https://kiket.dev/webhooks/ext/:webhook_token/status_callback
    context[:webhook_url]&.call('status_callback')
  end

  def normalize_phone_number(number, context)
    phone = Phonelib.parse(number, default_country_code(context))
    raise ArgumentError, "Invalid phone number: #{number}" unless phone.valid?

    phone.e164
  end

  def validate_sms_request!(payload)
    raise ArgumentError, 'Missing required field: to' unless payload['to']
    raise ArgumentError, 'Missing required field: message' unless payload['message']
    raise ArgumentError, 'Message too long (max 1600 chars)' if payload['message'].length > 1600
  end

  def validate_voice_request!(payload)
    raise ArgumentError, 'Missing required field: to' unless payload['to']
    raise ArgumentError, 'Missing required field: message' unless payload['message']
  end

  def validate_mms_request!(payload)
    raise ArgumentError, 'Missing required field: to' unless payload['to']
    raise ArgumentError, 'Missing required field: message' unless payload['message']
    raise ArgumentError, 'Missing required field: media_urls' unless payload['media_urls']
    raise ArgumentError, 'media_urls must be an array' unless payload['media_urls'].is_a?(Array)
    raise ArgumentError, 'At least one media URL required' if payload['media_urls'].empty?
  end

  def check_opt_in(phone_number)
    @opt_in_storage[phone_number] || false
  end

  def update_opt_in(phone_number, opted_in)
    @opt_in_storage[phone_number] = opted_in
  end

  def check_rate_limit!
    if Time.now >= @rate_limit_state[:reset_at]
      @rate_limit_state[:count] = 0
      @rate_limit_state[:reset_at] = Time.now + 60
    end

    max_per_minute = ENV.fetch('RATE_LIMIT_PER_MINUTE', '10').to_i
    raise RateLimitError, "Rate limit exceeded (#{max_per_minute}/min)" if @rate_limit_state[:count] >= max_per_minute
  end

  def increment_rate_limit!
    @rate_limit_state[:count] += 1
  end

  def generate_voice_twiml(message)
    <<~TWIML
      <?xml version="1.0" encoding="UTF-8"?>
      <Response>
        <Say voice="Polly.Joanna">#{escape_xml(message)}</Say>
        <Pause length="1"/>
        <Say voice="Polly.Joanna">This message will not be repeated. Goodbye.</Say>
      </Response>
    TWIML
  end

  def escape_xml(text)
    text.gsub('&', '&amp;')
        .gsub('<', '&lt;')
        .gsub('>', '&gt;')
        .gsub("'", '&apos;')
        .gsub('"', '&quot;')
  end
end

# Run the extension
if __FILE__ == $PROGRAM_NAME
  extension = TwilioNotificationExtension.new

  Rackup::Handler.get(:puma).run(
    extension.app,
    Host: ENV.fetch('HOST', '0.0.0.0'),
    Port: ENV.fetch('PORT', 8080).to_i,
    Threads: '0:16'
  )
end
