# frozen_string_literal: true

require "test_helper"

class Ai::HostGuardTest < ActiveSupport::TestCase
  should "name private hosts from the name alone" do
    %w[localhost app.local db.internal 127.0.0.1 10.1.2.3 192.168.0.1 172.16.0.1 169.254.169.254 ::1 0.0.0.0].each do |host|
      assert Ai::HostGuard.private_host?(host), host
    end
    %w[ai-gateway.vercel.sh api.anthropic.com 8.8.8.8].each { |host| assert_not Ai::HostGuard.private_host?(host), host }
  end

  should "see through an IPv4-mapped IPv6 literal" do
    assert Ai::HostGuard.private_address?("::ffff:10.0.0.1")
  end

  should "refuse a public name that resolves to a private address" do
    Resolv.stub(:getaddresses, [ "10.0.0.7" ]) do
      error = assert_raises(Ai::Errors::ApiError) { Ai::HostGuard.check!("https://innocent.example.com/v1") }
      assert_match(/private network/, error.message)
    end
  end

  should "let a public address through, and anything at all in development" do
    Resolv.stub(:getaddresses, [ "76.76.21.21" ]) { assert_nil Ai::HostGuard.check!("https://ai-gateway.vercel.sh/v1") }
    Rails.env.stub(:development?, true) { assert_nil Ai::HostGuard.check!("http://localhost:11434/v1") }
  end
end
