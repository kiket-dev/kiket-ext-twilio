# frozen_string_literal: true

require "spec_helper"

RSpec.describe TwilioNotificationExtension do
  def app
    TwilioNotificationExtension
  end

  let(:twilio_client) { instance_double(Twilio::REST::Client) }
  let(:messages_api) { instance_double(Twilio::REST::Api::V2010::AccountContext::MessageList) }
  let(:calls_api) { instance_double(Twilio::REST::Api::V2010::AccountContext::CallList) }

  before do
    allow(Twilio::REST::Client).to receive(:new).and_return(twilio_client)
    allow(twilio_client).to receive(:messages).and_return(messages_api)
    allow(twilio_client).to receive(:calls).and_return(calls_api)

    # Reset rate limiting between tests
    app.settings.rate_limit_state = { count: 0, reset_at: Time.now + 60 }
  end

  describe "GET /health" do
    it "returns healthy status" do
      get "/health"

      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json["status"]).to eq("healthy")
      expect(json["service"]).to eq("twilio-notifications")
      expect(json["version"]).to eq("1.0.0")
      expect(json["twilio_configured"]).to be true
    end
  end

  describe "POST /sms" do
    context "with valid request" do
      let(:message) do
        instance_double(
          Twilio::REST::Api::V2010::AccountContext::MessageInstance,
          sid: "SM123abc",
          to: "+15559876543",
          status: "queued"
        )
      end

      it "sends SMS successfully" do
        allow(messages_api).to receive(:create).and_return(message)

        post "/sms", JSON.generate({
          to: "+15559876543",
          message: "Test message"
        }), { "CONTENT_TYPE" => "application/json" }

        expect(last_response).to be_ok
        json = JSON.parse(last_response.body)
        expect(json["success"]).to be true
        expect(json["message_sid"]).to eq("SM123abc")
        expect(json["to"]).to eq("+15559876543")
        expect(json["status"]).to eq("queued")

        expect(messages_api).to have_received(:create).with(
          hash_including(
            from: "+15551234567",
            to: "+15559876543",
            body: "Test message"
          )
        )
      end

      it "normalizes phone numbers" do
        allow(messages_api).to receive(:create).and_return(message)

        post "/sms", JSON.generate({
          to: "(555) 987-6543",  # US format
          message: "Test"
        }), { "CONTENT_TYPE" => "application/json" }

        expect(last_response).to be_ok
        expect(messages_api).to have_received(:create).with(
          hash_including(to: "+15559876543")
        )
      end
    end

    context "with validation errors" do
      it "requires recipient" do
        post "/sms", JSON.generate({
          message: "Test"
        }), { "CONTENT_TYPE" => "application/json" }

        expect(last_response.status).to eq(400)
        json = JSON.parse(last_response.body)
        expect(json["error"]).to include("Recipient")
      end

      it "requires message" do
        post "/sms", JSON.generate({
          to: "+15559876543"
        }), { "CONTENT_TYPE" => "application/json" }

        expect(last_response.status).to eq(400)
        json = JSON.parse(last_response.body)
        expect(json["error"]).to include("message")
      end

      it "validates phone number format" do
        post "/sms", JSON.generate({
          to: "invalid",
          message: "Test"
        }), { "CONTENT_TYPE" => "application/json" }

        expect(last_response.status).to eq(400)
        json = JSON.parse(last_response.body)
        expect(json["error"]).to include("Invalid phone number")
      end

      it "handles invalid JSON" do
        post "/sms", "invalid json", { "CONTENT_TYPE" => "application/json" }

        expect(last_response.status).to eq(400)
        json = JSON.parse(last_response.body)
        expect(json["error"]).to include("Invalid JSON")
      end
    end

    context "with rate limiting" do
      let(:message) do
        instance_double(
          Twilio::REST::Api::V2010::AccountContext::MessageInstance,
          sid: "SM123",
          to: "+15559876543",
          status: "queued"
        )
      end

      it "enforces rate limits" do
        allow(messages_api).to receive(:create).and_return(message)

        # Send messages up to the limit (default 10)
        11.times do |i|
          post "/sms", JSON.generate({
            to: "+1555000000#{i}",
            message: "Test"
          }), { "CONTENT_TYPE" => "application/json" }
        end

        # Last request should be rate limited
        expect(last_response.status).to eq(400)
        json = JSON.parse(last_response.body)
        expect(json["error"]).to include("Rate limit exceeded")
      end
    end

    context "with opt-in requirement" do
      let(:message) do
        instance_double(
          Twilio::REST::Api::V2010::AccountContext::MessageInstance,
          sid: "SM123",
          to: "+15559876543",
          status: "queued"
        )
      end

      it "checks opt-in status when required" do
        # Opt-in is required by default
        post "/sms", JSON.generate({
          to: "+15559876543",
          message: "Test"
        }), { "CONTENT_TYPE" => "application/json" }

        expect(last_response.status).to eq(400)
        json = JSON.parse(last_response.body)
        expect(json["error"]).to include("not opted in")
      end

      it "allows sending after opt-in" do
        allow(messages_api).to receive(:create).and_return(message)

        # Update opt-in status
        post "/opt-in/update", JSON.generate({
          phone_number: "+15559876543",
          opted_in: true
        }), { "CONTENT_TYPE" => "application/json" }

        # Now send should work
        post "/sms", JSON.generate({
          to: "+15559876543",
          message: "Test"
        }), { "CONTENT_TYPE" => "application/json" }

        expect(last_response).to be_ok
      end
    end

    context "with Twilio API errors" do
      it "handles Twilio errors gracefully" do
        allow(messages_api).to receive(:create).and_raise(
          Twilio::REST::RestError.new("Authentication failed", 20003)
        )

        # Update opt-in first
        post "/opt-in/update", JSON.generate({
          phone_number: "+15559876543",
          opted_in: true
        }), { "CONTENT_TYPE" => "application/json" }

        post "/sms", JSON.generate({
          to: "+15559876543",
          message: "Test"
        }), { "CONTENT_TYPE" => "application/json" }

        expect(last_response.status).to eq(502)
        json = JSON.parse(last_response.body)
        expect(json["error"]).to include("Twilio API error")
      end
    end
  end

  describe "POST /voice" do
    let(:call) do
      instance_double(
        Twilio::REST::Api::V2010::AccountContext::CallInstance,
        sid: "CA123abc",
        to: "+15559876543",
        status: "queued"
      )
    end

    it "initiates voice call successfully" do
      allow(calls_api).to receive(:create).and_return(call)

      # Update opt-in first
      post "/opt-in/update", JSON.generate({
        phone_number: "+15559876543",
        opted_in: true
      }), { "CONTENT_TYPE" => "application/json" }

      post "/voice", JSON.generate({
        to: "+15559876543",
        message: "This is a test call"
      }), { "CONTENT_TYPE" => "application/json" }

      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json["success"]).to be true
      expect(json["call_sid"]).to eq("CA123abc")
      expect(json["status"]).to eq("queued")

      expect(calls_api).to have_received(:create).with(
        hash_including(
          from: "+15551234567",
          to: "+15559876543"
        )
      )
    end
  end

  describe "POST /mms" do
    let(:message) do
      instance_double(
        Twilio::REST::Api::V2010::AccountContext::MessageInstance,
        sid: "MM123abc",
        to: "+15559876543",
        status: "queued"
      )
    end

    it "sends MMS with media" do
      allow(messages_api).to receive(:create).and_return(message)

      # Update opt-in first
      post "/opt-in/update", JSON.generate({
        phone_number: "+15559876543",
        opted_in: true
      }), { "CONTENT_TYPE" => "application/json" }

      post "/mms", JSON.generate({
        to: "+15559876543",
        message: "Check this out",
        media_urls: [ "https://example.com/image.jpg" ]
      }), { "CONTENT_TYPE" => "application/json" }

      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json["success"]).to be true
      expect(json["message_sid"]).to eq("MM123abc")

      expect(messages_api).to have_received(:create).with(
        hash_including(
          media_url: [ "https://example.com/image.jpg" ]
        )
      )
    end

    it "requires media URLs" do
      post "/mms", JSON.generate({
        to: "+15559876543",
        message: "Test"
      }), { "CONTENT_TYPE" => "application/json" }

      expect(last_response.status).to eq(400)
      json = JSON.parse(last_response.body)
      expect(json["error"]).to include("media")
    end
  end

  describe "POST /opt-in/update" do
    it "updates opt-in status" do
      post "/opt-in/update", JSON.generate({
        phone_number: "+15559876543",
        opted_in: true
      }), { "CONTENT_TYPE" => "application/json" }

      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json["success"]).to be true
      expect(json["phone_number"]).to eq("+15559876543")
      expect(json["opted_in"]).to be true
    end

    it "normalizes phone numbers" do
      post "/opt-in/update", JSON.generate({
        phone_number: "(555) 987-6543",
        opted_in: true
      }), { "CONTENT_TYPE" => "application/json" }

      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json["phone_number"]).to eq("+15559876543")
    end
  end

  describe "POST /opt-in/check" do
    it "checks opt-in status" do
      # Set opt-in first
      post "/opt-in/update", JSON.generate({
        phone_number: "+15559876543",
        opted_in: true
      }), { "CONTENT_TYPE" => "application/json" }

      # Check status
      post "/opt-in/check", JSON.generate({
        phone_number: "+15559876543"
      }), { "CONTENT_TYPE" => "application/json" }

      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json["success"]).to be true
      expect(json["opted_in"]).to be true
    end

    it "returns false for unknown numbers" do
      post "/opt-in/check", JSON.generate({
        phone_number: "+15559999999"
      }), { "CONTENT_TYPE" => "application/json" }

      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json["opted_in"]).to be false
    end
  end

  describe "POST /validate" do
    it "validates valid phone number" do
      post "/validate", JSON.generate({
        phone_number: "+15559876543"
      }), { "CONTENT_TYPE" => "application/json" }

      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json["success"]).to be true
      expect(json["valid"]).to be true
      expect(json["e164_format"]).to eq("+15559876543")
    end

    it "rejects invalid phone number" do
      post "/validate", JSON.generate({
        phone_number: "invalid"
      }), { "CONTENT_TYPE" => "application/json" }

      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json["valid"]).to be false
    end

    it "normalizes various formats" do
      post "/validate", JSON.generate({
        phone_number: "(555) 987-6543"
      }), { "CONTENT_TYPE" => "application/json" }

      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json["valid"]).to be true
      expect(json["e164_format"]).to eq("+15559876543")
      expect(json["national_format"]).to eq("(555) 987-6543")
    end
  end
end
