# frozen_string_literal: true

require "test_helper"

class AiModelCredentialsTest < ActiveSupport::TestCase
  should "read the key and nothing else" do
    credentials = AiModelCredentials.new({ "api_key" => "sk-secret", "other" => "x" })

    assert_equal "sk-secret", credentials.api_key
    assert credentials.api_key?
  end

  should "treat nil, a blank key and a non-hash as no key" do
    [ nil, {}, { "api_key" => "" }, "sk-secret" ].each { |raw| assert_not AiModelCredentials.new(raw).api_key?, raw.inspect }
  end

  should "never print the key" do
    credentials = AiModelCredentials.new({ "api_key" => "sk-secret" })

    assert_equal "#<AiModelCredentials api_key=true>", credentials.inspect
    assert_equal credentials.inspect, credentials.to_s
    assert_no_match(/sk-secret/, "#{credentials}")
  end
end
