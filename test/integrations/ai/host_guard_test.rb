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

  should "see through the shorthand the system resolver accepts for IPv4" do
    %w[127.1 2130706433 0x7f000001 0177.0.0.1 0x7f.1 167772161 0xa000001].each do |host|
      assert Ai::HostGuard.private_host?(host), host
    end
    assert_not Ai::HostGuard.private_host?("134744072"), "8.8.8.8 written as one number is public"
  end

  should "block this network and carrier-grade NAT" do
    %w[0.1.2.3 100.64.0.1 100.127.255.254].each { |address| assert Ai::HostGuard.private_address?(address), address }
    assert_not Ai::HostGuard.private_address?("100.128.0.1")
  end

  should "refuse a public name that resolves to a private address" do
    Addrinfo.stub(:getaddrinfo, [ Addrinfo.ip("10.0.0.7") ]) do
      error = assert_raises(Ai::Errors::ConfigurationError) { Ai::HostGuard.check!("https://innocent.example.com/v1") }
      assert_match(/private network/, error.message)
    end
  end

  should "refuse a shorthand host without asking DNS" do
    assert_raises(Ai::Errors::ConfigurationError) { Ai::HostGuard.check!("https://127.1/v1") }
    assert_raises(Ai::Errors::ConfigurationError) { Ai::HostGuard.check!("https://2130706433") }
  end

  should "let a public address through, and anything at all in development" do
    Addrinfo.stub(:getaddrinfo, [ Addrinfo.ip("76.76.21.21") ]) { assert_nil Ai::HostGuard.check!("https://ai-gateway.vercel.sh/v1") }
    Rails.env.stub(:development?, true) { assert_nil Ai::HostGuard.check!("http://localhost:11434/v1") }
  end

  should "let an unresolvable name through to fail at the connection" do
    Addrinfo.stub(:getaddrinfo, ->(*) { raise SocketError, "getaddrinfo: Name or service not known" }) do
      assert_nil Ai::HostGuard.check!("https://nowhere.example.com/v1")
    end
  end
end
