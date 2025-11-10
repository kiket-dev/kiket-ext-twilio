# frozen_string_literal: true

require "sinatra/base"
require "json"
require "twilio-ruby"
require "phonelib"
require "logger"

# Twilio Notification Extension
# Handles sending SMS, MMS, and voice notifications via Twilio
class TwilioNotificationExtension < Sinatra::Base
  configure do
    set :logging, true
    set :logger, Logger.new($stdout)

    # Initialize Twilio client
    set :twilio_client, Twilio::REST::Client.new(
      ENV["TWILIO_ACCOUNT_SID"],
      ENV["TWILIO_AUTH_TOKEN"]
    )

    # Initialize opt-in storage (in-memory for now)
    set :opt_in_storage, {}

    # Rate limiting state
    set :rate_limit_state, { count: 0, reset_at: Time.now + 60 }
  end

  # Health check endpoint
  get "/health" do
    content_type :json
    {
      status: "healthy",
      service: "twilio-notifications",
      version: "1.0.0",
      timestamp: Time.now.utc.iso8601,
      twilio_configured: twilio_configured?
    }.to_json
  end

  # Send SMS notification
  post "/sms" do
    content_type :json

    begin
      request_body = JSON.parse(request.body.read, symbolize_names: true)

      # Validate required fields
      validate_sms_request!(request_body)

      # Check rate limiting
      check_rate_limit!

      # Normalize phone number
      to_number = normalize_phone_number(request_body[:to])

      # Check opt-in if required
      if opt_in_required? && !check_opt_in(to_number)
        raise OptInError, "Recipient #{to_number} has not opted in for SMS notifications"
      end

      # Send SMS via Twilio
      message = settings.twilio_client.messages.create(
        from: twilio_phone_number,
        to: to_number,
        body: request_body[:message],
        status_callback: status_callback_url
      )

      # Increment rate limit counter
      increment_rate_limit!

      status 200
      {
        success: true,
        message_sid: message.sid,
        to: message.to,
        status: message.status,
        sent_at: Time.now.utc.iso8601
      }.to_json

    rescue JSON::ParserError => e
      logger.error "Invalid JSON: #{e.message}"
      status 400
      { success: false, error: "Invalid JSON in request body" }.to_json

    rescue ArgumentError, OptInError, RateLimitError => e
      logger.error "Validation error: #{e.message}"
      status 400
      { success: false, error: e.message }.to_json

    rescue Twilio::REST::RestError => e
      logger.error "Twilio API error: #{e.message}"
      status 502
      {
        success: false,
        error: "Twilio API error: #{e.message}",
        error_code: e.code
      }.to_json

    rescue StandardError => e
      logger.error "Unexpected error: #{e.message}\n#{e.backtrace.join("\n")}"
      status 500
      { success: false, error: "Internal server error" }.to_json
    end
  end

  # Send voice call notification
  post "/voice" do
    content_type :json

    begin
      request_body = JSON.parse(request.body.read, symbolize_names: true)

      # Validate required fields
      validate_voice_request!(request_body)

      # Check rate limiting
      check_rate_limit!

      # Normalize phone number
      to_number = normalize_phone_number(request_body[:to])

      # Check opt-in if required
      if opt_in_required? && !check_opt_in(to_number)
        raise OptInError, "Recipient #{to_number} has not opted in for voice notifications"
      end

      # Create TwiML for voice message
      twiml = generate_voice_twiml(request_body[:message])

      # Send voice call via Twilio
      call = settings.twilio_client.calls.create(
        from: twilio_phone_number,
        to: to_number,
        twiml: twiml,
        status_callback: status_callback_url,
        status_callback_event: %w[initiated ringing answered completed]
      )

      # Increment rate limit counter
      increment_rate_limit!

      status 200
      {
        success: true,
        call_sid: call.sid,
        to: call.to,
        status: call.status,
        initiated_at: Time.now.utc.iso8601
      }.to_json

    rescue JSON::ParserError => e
      logger.error "Invalid JSON: #{e.message}"
      status 400
      { success: false, error: "Invalid JSON in request body" }.to_json

    rescue ArgumentError, OptInError, RateLimitError => e
      logger.error "Validation error: #{e.message}"
      status 400
      { success: false, error: e.message }.to_json

    rescue Twilio::REST::RestError => e
      logger.error "Twilio API error: #{e.message}"
      status 502
      {
        success: false,
        error: "Twilio API error: #{e.message}",
        error_code: e.code
      }.to_json

    rescue StandardError => e
      logger.error "Unexpected error: #{e.message}\n#{e.backtrace.join("\n")}"
      status 500
      { success: false, error: "Internal server error" }.to_json
    end
  end

  # Send MMS notification with media
  post "/mms" do
    content_type :json

    begin
      request_body = JSON.parse(request.body.read, symbolize_names: true)

      # Validate required fields
      validate_mms_request!(request_body)

      # Check rate limiting
      check_rate_limit!

      # Normalize phone number
      to_number = normalize_phone_number(request_body[:to])

      # Check opt-in if required
      if opt_in_required? && !check_opt_in(to_number)
        raise OptInError, "Recipient #{to_number} has not opted in for MMS notifications"
      end

      # Send MMS via Twilio
      message = settings.twilio_client.messages.create(
        from: twilio_phone_number,
        to: to_number,
        body: request_body[:message],
        media_url: request_body[:media_urls],
        status_callback: status_callback_url
      )

      # Increment rate limit counter
      increment_rate_limit!

      status 200
      {
        success: true,
        message_sid: message.sid,
        to: message.to,
        status: message.status,
        media_count: message.num_media.to_i,
        sent_at: Time.now.utc.iso8601
      }.to_json

    rescue JSON::ParserError => e
      logger.error "Invalid JSON: #{e.message}"
      status 400
      { success: false, error: "Invalid JSON in request body" }.to_json

    rescue ArgumentError, OptInError, RateLimitError => e
      logger.error "Validation error: #{e.message}"
      status 400
      { success: false, error: e.message }.to_json

    rescue Twilio::REST::RestError => e
      logger.error "Twilio API error: #{e.message}"
      status 502
      {
        success: false,
        error: "Twilio API error: #{e.message}",
        error_code: e.code
      }.to_json

    rescue StandardError => e
      logger.error "Unexpected error: #{e.message}\n#{e.backtrace.join("\n")}"
      status 500
      { success: false, error: "Internal server error" }.to_json
    end
  end

  # Check opt-in status
  post "/opt-in/check" do
    content_type :json

    begin
      request_body = JSON.parse(request.body.read, symbolize_names: true)

      raise ArgumentError, "Missing required field: phone_number" unless request_body[:phone_number]

      phone_number = normalize_phone_number(request_body[:phone_number])
      opted_in = check_opt_in(phone_number)

      status 200
      {
        success: true,
        phone_number: phone_number,
        opted_in: opted_in,
        checked_at: Time.now.utc.iso8601
      }.to_json

    rescue JSON::ParserError => e
      status 400
      { success: false, error: "Invalid JSON in request body" }.to_json

    rescue ArgumentError => e
      status 400
      { success: false, error: e.message }.to_json

    rescue StandardError => e
      logger.error "Unexpected error: #{e.message}"
      status 500
      { success: false, error: "Internal server error" }.to_json
    end
  end

  # Update opt-in status
  post "/opt-in/update" do
    content_type :json

    begin
      request_body = JSON.parse(request.body.read, symbolize_names: true)

      raise ArgumentError, "Missing required field: phone_number" unless request_body[:phone_number]
      raise ArgumentError, "Missing required field: opted_in" if request_body[:opted_in].nil?

      phone_number = normalize_phone_number(request_body[:phone_number])
      opted_in = request_body[:opted_in]

      update_opt_in(phone_number, opted_in)

      status 200
      {
        success: true,
        phone_number: phone_number,
        opted_in: opted_in,
        updated_at: Time.now.utc.iso8601
      }.to_json

    rescue JSON::ParserError => e
      status 400
      { success: false, error: "Invalid JSON in request body" }.to_json

    rescue ArgumentError => e
      status 400
      { success: false, error: e.message }.to_json

    rescue StandardError => e
      logger.error "Unexpected error: #{e.message}"
      status 500
      { success: false, error: "Internal server error" }.to_json
    end
  end

  # Validate phone number
  post "/validate" do
    content_type :json

    begin
      request_body = JSON.parse(request.body.read, symbolize_names: true)

      raise ArgumentError, "Missing required field: phone_number" unless request_body[:phone_number]

      phone = Phonelib.parse(request_body[:phone_number], default_country_code)

      status 200
      {
        success: true,
        phone_number: request_body[:phone_number],
        valid: phone.valid?,
        e164_format: phone.e164,
        country: phone.country,
        national_format: phone.national,
        type: phone.type,
        possible: phone.possible?
      }.to_json

    rescue JSON::ParserError => e
      status 400
      { success: false, error: "Invalid JSON in request body" }.to_json

    rescue ArgumentError => e
      status 400
      { success: false, error: e.message }.to_json

    rescue StandardError => e
      logger.error "Unexpected error: #{e.message}"
      status 500
      { success: false, error: "Internal server error" }.to_json
    end
  end

  # Webhook endpoint for Twilio status callbacks
  post "/webhooks/status" do
    content_type :json

    begin
      # Log the status callback (in production, this would update a database)
      logger.info "Twilio status callback: #{params.inspect}"

      # Respond with 200 OK to acknowledge receipt
      status 200
      { success: true, received_at: Time.now.utc.iso8601 }.to_json

    rescue StandardError => e
      logger.error "Webhook processing error: #{e.message}"
      status 500
      { success: false, error: "Webhook processing failed" }.to_json
    end
  end

  private

  # Custom error classes
  class OptInError < StandardError; end
  class RateLimitError < StandardError; end

  def twilio_configured?
    ENV["TWILIO_ACCOUNT_SID"].present? &&
      ENV["TWILIO_AUTH_TOKEN"].present? &&
      ENV["TWILIO_PHONE_NUMBER"].present?
  end

  def twilio_phone_number
    ENV["TWILIO_PHONE_NUMBER"]
  end

  def default_country_code
    ENV.fetch("DEFAULT_COUNTRY_CODE", "US")
  end

  def opt_in_required?
    ENV.fetch("REQUIRE_OPT_IN", "true") == "true"
  end

  def rate_limit_per_minute
    ENV.fetch("RATE_LIMIT_PER_MINUTE", "10").to_i
  end

  def status_callback_url
    return nil unless ENV.fetch("ENABLE_DELIVERY_TRACKING", "true") == "true"

    # In production, this would be the public webhook URL
    # For now, return nil to disable status callbacks in development
    ENV["TWILIO_STATUS_CALLBACK_URL"]
  end

  def normalize_phone_number(number)
    phone = Phonelib.parse(number, default_country_code)
    raise ArgumentError, "Invalid phone number: #{number}" unless phone.valid?

    phone.e164
  end

  def validate_sms_request!(body)
    raise ArgumentError, "Missing required field: to" unless body[:to]
    raise ArgumentError, "Missing required field: message" unless body[:message]
    raise ArgumentError, "Message too long (max 1600 chars)" if body[:message].length > 1600
  end

  def validate_voice_request!(body)
    raise ArgumentError, "Missing required field: to" unless body[:to]
    raise ArgumentError, "Missing required field: message" unless body[:message]
  end

  def validate_mms_request!(body)
    raise ArgumentError, "Missing required field: to" unless body[:to]
    raise ArgumentError, "Missing required field: message" unless body[:message]
    raise ArgumentError, "Missing required field: media_urls" unless body[:media_urls]
    raise ArgumentError, "media_urls must be an array" unless body[:media_urls].is_a?(Array)
    raise ArgumentError, "At least one media URL required" if body[:media_urls].empty?
  end

  def check_opt_in(phone_number)
    # In-memory storage for demonstration
    # In production, this would query a database or Redis
    settings.opt_in_storage[phone_number] || false
  end

  def update_opt_in(phone_number, opted_in)
    # In-memory storage for demonstration
    # In production, this would update a database or Redis
    settings.opt_in_storage[phone_number] = opted_in
  end

  def check_rate_limit!
    state = settings.rate_limit_state

    # Reset counter if time window has passed
    if Time.now >= state[:reset_at]
      state[:count] = 0
      state[:reset_at] = Time.now + 60
    end

    # Check if rate limit exceeded
    raise RateLimitError, "Rate limit exceeded (#{rate_limit_per_minute}/min)" if state[:count] >= rate_limit_per_minute
  end

  def increment_rate_limit!
    settings.rate_limit_state[:count] += 1
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
    text.gsub("&", "&amp;")
        .gsub("<", "&lt;")
        .gsub(">", "&gt;")
        .gsub("'", "&apos;")
        .gsub('"', "&quot;")
  end
end

# Convenience method for String presence check
class String
  def present?
    !nil? && !empty?
  end
end

class NilClass
  def present?
    false
  end
end
