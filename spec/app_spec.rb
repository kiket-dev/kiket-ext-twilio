# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TwilioNotificationExtension do
  subject(:extension) { described_class.new }

  let(:twilio_client) { instance_double(Twilio::REST::Client) }
  let(:messages_api) { instance_double(Twilio::REST::Api::V2010::AccountContext::MessageList) }
  let(:calls_api) { instance_double(Twilio::REST::Api::V2010::AccountContext::CallList) }

  let(:context) { build_context }
  let(:context_no_opt_in) do
    build_context(
      secret: lambda { |key|
        case key
        when 'REQUIRE_OPT_IN' then 'false'
        when 'TWILIO_ACCOUNT_SID' then 'test_account_sid'
        when 'TWILIO_AUTH_TOKEN' then 'test_auth_token'
        when 'TWILIO_PHONE_NUMBER' then '+15551234567'
        when 'DEFAULT_COUNTRY_CODE' then 'US'
        when 'ENABLE_DELIVERY_TRACKING' then 'false'
        else ENV.fetch(key, nil)
        end
      }
    )
  end

  before do
    allow(Twilio::REST::Client).to receive(:new).and_return(twilio_client)
    allow(twilio_client).to receive_messages(messages: messages_api, calls: calls_api)
  end

  describe '#handle_send_sms' do
    let(:message) do
      instance_double(
        Twilio::REST::Api::V2010::AccountContext::MessageInstance,
        sid: 'SM123abc',
        to: '+15559876543',
        status: 'queued'
      )
    end

    let(:payload) do
      {
        'to' => '+15559876543',
        'message' => 'Test message'
      }
    end

    context 'with valid request and no opt-in required' do
      it 'sends SMS successfully' do
        allow(messages_api).to receive(:create).and_return(message)

        result = extension.send(:handle_send_sms, payload, context_no_opt_in)

        expect(result[:success]).to be true
        expect(result[:message_sid]).to eq('SM123abc')
        expect(result[:to]).to eq('+15559876543')
        expect(result[:status]).to eq('queued')
      end

      it 'normalizes phone numbers' do
        allow(messages_api).to receive(:create).and_return(message)

        result = extension.send(:handle_send_sms, payload.merge('to' => '(555) 987-6543'), context_no_opt_in)

        expect(result[:success]).to be true
        expect(messages_api).to have_received(:create).with(
          hash_including(to: '+15559876543')
        )
      end
    end

    context 'with validation errors' do
      it 'requires recipient' do
        result = extension.send(:handle_send_sms, { 'message' => 'Test' }, context_no_opt_in)

        expect(result[:success]).to be false
        expect(result[:error]).to include('to')
      end

      it 'requires message' do
        result = extension.send(:handle_send_sms, { 'to' => '+15559876543' }, context_no_opt_in)

        expect(result[:success]).to be false
        expect(result[:error]).to include('message')
      end

      it 'validates phone number format' do
        result = extension.send(:handle_send_sms, {
                                  'to' => 'invalid',
                                  'message' => 'Test'
                                }, context_no_opt_in)

        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid phone number')
      end
    end

    context 'with opt-in requirement' do
      it 'checks opt-in status when required' do
        result = extension.send(:handle_send_sms, payload, context)

        expect(result[:success]).to be false
        expect(result[:error]).to include('not opted in')
      end

      it 'allows sending after opt-in' do
        allow(messages_api).to receive(:create).and_return(message)

        # Update opt-in status
        extension.send(:handle_update_opt_in, {
                         'phone_number' => '+15559876543',
                         'opted_in' => true
                       }, context)

        result = extension.send(:handle_send_sms, payload, context)

        expect(result[:success]).to be true
      end
    end

    context 'with Twilio API errors' do
      it 'handles Twilio errors gracefully' do
        allow(messages_api).to receive(:create).and_raise(
          Twilio::REST::RestError.new('Authentication failed', 20_003)
        )

        result = extension.send(:handle_send_sms, payload, context_no_opt_in)

        expect(result[:success]).to be false
        expect(result[:error]).to include('Twilio API error')
      end
    end
  end

  describe '#handle_send_voice' do
    let(:call) do
      instance_double(
        Twilio::REST::Api::V2010::AccountContext::CallInstance,
        sid: 'CA123abc',
        to: '+15559876543',
        status: 'queued'
      )
    end

    let(:payload) do
      {
        'to' => '+15559876543',
        'message' => 'This is a test call'
      }
    end

    it 'initiates voice call successfully' do
      allow(calls_api).to receive(:create).and_return(call)

      # Update opt-in first
      extension.send(:handle_update_opt_in, {
                       'phone_number' => '+15559876543',
                       'opted_in' => true
                     }, context)

      result = extension.send(:handle_send_voice, payload, context)

      expect(result[:success]).to be true
      expect(result[:call_sid]).to eq('CA123abc')
      expect(result[:status]).to eq('queued')
    end
  end

  describe '#handle_send_mms' do
    let(:message) do
      instance_double(
        Twilio::REST::Api::V2010::AccountContext::MessageInstance,
        sid: 'MM123abc',
        to: '+15559876543',
        status: 'queued',
        num_media: '1'
      )
    end

    let(:payload) do
      {
        'to' => '+15559876543',
        'message' => 'Check this out',
        'media_urls' => ['https://example.com/image.jpg']
      }
    end

    it 'sends MMS with media' do
      allow(messages_api).to receive(:create).and_return(message)

      # Update opt-in first
      extension.send(:handle_update_opt_in, {
                       'phone_number' => '+15559876543',
                       'opted_in' => true
                     }, context)

      result = extension.send(:handle_send_mms, payload, context)

      expect(result[:success]).to be true
      expect(result[:message_sid]).to eq('MM123abc')
    end

    it 'requires media URLs' do
      result = extension.send(:handle_send_mms, {
                                'to' => '+15559876543',
                                'message' => 'Test'
                              }, context_no_opt_in)

      expect(result[:success]).to be false
      expect(result[:error]).to include('media')
    end
  end

  describe '#handle_update_opt_in' do
    it 'updates opt-in status' do
      result = extension.send(:handle_update_opt_in, {
                                'phone_number' => '+15559876543',
                                'opted_in' => true
                              }, context)

      expect(result[:success]).to be true
      expect(result[:phone_number]).to eq('+15559876543')
      expect(result[:opted_in]).to be true
    end

    it 'normalizes phone numbers' do
      result = extension.send(:handle_update_opt_in, {
                                'phone_number' => '(555) 987-6543',
                                'opted_in' => true
                              }, context)

      expect(result[:success]).to be true
      expect(result[:phone_number]).to eq('+15559876543')
    end
  end

  describe '#handle_check_opt_in' do
    it 'checks opt-in status' do
      # Set opt-in first
      extension.send(:handle_update_opt_in, {
                       'phone_number' => '+15559876543',
                       'opted_in' => true
                     }, context)

      result = extension.send(:handle_check_opt_in, {
                                'phone_number' => '+15559876543'
                              }, context)

      expect(result[:success]).to be true
      expect(result[:opted_in]).to be true
    end

    it 'returns false for unknown numbers' do
      result = extension.send(:handle_check_opt_in, {
                                'phone_number' => '+15559999999'
                              }, context)

      expect(result[:success]).to be true
      expect(result[:opted_in]).to be false
    end
  end

  describe '#handle_validate_phone' do
    it 'validates valid phone number' do
      result = extension.send(:handle_validate_phone, {
                                'phone_number' => '+15559876543'
                              }, context)

      expect(result[:success]).to be true
      expect(result[:valid]).to be true
      expect(result[:e164_format]).to eq('+15559876543')
    end

    it 'provides info for invalid phone number' do
      result = extension.send(:handle_validate_phone, {
                                'phone_number' => 'invalid'
                              }, context)

      expect(result[:success]).to be true
      expect(result[:valid]).to be false
    end

    it 'normalizes various formats' do
      result = extension.send(:handle_validate_phone, {
                                'phone_number' => '(555) 987-6543'
                              }, context)

      expect(result[:success]).to be true
      expect(result[:valid]).to be true
      expect(result[:e164_format]).to eq('+15559876543')
    end
  end

  describe '#handle_status_webhook' do
    it 'processes webhook payload' do
      result = extension.send(:handle_status_webhook, {
                                'MessageSid' => 'SM123',
                                'MessageStatus' => 'delivered'
                              }, context)

      expect(result[:success]).to be true
      expect(result[:received_at]).to match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
    end
  end
end
