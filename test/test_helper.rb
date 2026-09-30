# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "support/explorer_write_stream_assertions"
require_relative "support/out_of_scope_ratings"

OmniAuth.config.test_mode = true
OmniAuth.config.logger = Rails.logger

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    include FactoryBot::Syntax::Methods

    teardown do
      OmniAuth.config.mock_auth.clear
    end

    # Add more helper methods to be used by all tests here...
  end
end

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :minitest
    with.library :rails
  end
end
