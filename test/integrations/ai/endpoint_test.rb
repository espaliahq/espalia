# frozen_string_literal: true

require "test_helper"

# {Ai::Endpoint} is a thin voice over {FeedbackExchange::HostGuard}, whose own
# tests cover the guard. These pin the translation and the one shape the AI
# adapters depend on: the accepted address comes back.
class Ai::EndpointTest < ActiveSupport::TestCase
  should "return the public address the guard accepted" do
    Addrinfo.stub(:getaddrinfo, [ Addrinfo.ip("76.76.21.21") ]) do
      assert_equal "76.76.21.21", Ai::Endpoint.vet!("https://ai-gateway.vercel.sh/v1")
    end
  end

  should "refuse private and shorthand hosts in the AI error set, naming the model endpoint" do
    [ "https://10.0.0.5/v1", "https://127.1/v1", "https://2130706433", "https://localhost:11434" ].each do |url|
      error = assert_raises(Ai::Errors::ConfigurationError, url) { Ai::Endpoint.vet!(url) }

      assert_match(/\AThe model endpoint's address/, error.message)
      assert_no_match(/peer/, error.message)
    end
  end

  should "refuse a name that resolves inward" do
    Addrinfo.stub(:getaddrinfo, [ Addrinfo.ip("10.0.0.7") ]) do
      assert_raises(Ai::Errors::ConfigurationError) { Ai::Endpoint.vet!("https://innocent.example.com/v1") }
    end
  end

  should "let development reach a local model server" do
    Rails.env.stub(:development?, true) { assert_nil Ai::Endpoint.vet!("http://localhost:11434/v1") }
  end
end
