# frozen_string_literal: true

ENV["RACK_ENV"] = "test"
ENV["TWILIO_ACCOUNT_SID"] = "test_account_sid"
ENV["TWILIO_AUTH_TOKEN"] = "test_auth_token"
ENV["TWILIO_PHONE_NUMBER"] = "+15551234567"

require "rspec"
require "rack/test"
require "webmock/rspec"
require "vcr"

require_relative "../app"

RSpec.configure do |config|
  config.include Rack::Test::Methods

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = "spec/examples.txt"
  config.disable_monkey_patching!
  config.warnings = true
  config.order = :random
  Kernel.srand config.seed
end

VCR.configure do |config|
  config.cassette_library_dir = "spec/fixtures/vcr_cassettes"
  config.hook_into :webmock
  config.configure_rspec_metadata!
  config.filter_sensitive_data("<TWILIO_ACCOUNT_SID>") { ENV["TWILIO_ACCOUNT_SID"] }
  config.filter_sensitive_data("<TWILIO_AUTH_TOKEN>") { ENV["TWILIO_AUTH_TOKEN"] }
end
