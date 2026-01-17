# frozen_string_literal: true

source "https://rubygems.org"

ruby "~> 3.4"

# Kiket SDK for extension development
gem "kiket-sdk", github: "kiket-dev/kiket-ruby-sdk", branch: "main"

# Twilio API client
gem "twilio-ruby", "~> 7.3"
gem "phonelib", "~> 0.9"

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "rack-test", "~> 2.1"
  gem "webmock", "~> 3.23"
  gem "vcr", "~> 6.3"
  gem "dotenv", "~> 3.1"
  gem "rubocop", "~> 1.69", require: false
end
