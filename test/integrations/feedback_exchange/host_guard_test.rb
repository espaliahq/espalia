# frozen_string_literal: true

require "test_helper"

class FeedbackExchange::HostGuardTest < ActiveSupport::TestCase
  NON_CANONICAL_LOOPBACKS = %w[127.1 2130706433 0x7f000001 0177.0.0.1 0x7f.0.0.1 127.0.1 017700000001].freeze

  def refused?(url)
    FeedbackExchange::HostGuard.check!(url)
    false
  rescue FeedbackExchange::Errors::AddressRefused
    true
  end

  context ".canonical_host?" do
    should "refuse the non-canonical IPv4 forms the system resolver reads as loopback" do
      NON_CANONICAL_LOOPBACKS.each do |host|
        assert_not FeedbackExchange::HostGuard.canonical_host?(host), "expected #{host} to be refused"
      end
    end

    should "accept hostnames, canonical dotted quads and IPv6 literals" do
      %w[chip.example.com a-b.example.co 93.184.216.34 [2606:2800:220:1::1] ::1].each do |host|
        assert FeedbackExchange::HostGuard.canonical_host?(host), "expected #{host} to be accepted"
      end
    end

    should "refuse malformed names" do
      [ "", "-a.example.com", "a..example.com", "a b.example.com", "exa_mple.com", "1.2.3", "1.2.3.4.5", "256.1.1.1", "[nope]" ].each do |host|
        assert_not FeedbackExchange::HostGuard.canonical_host?(host), "expected #{host.inspect} to be refused"
      end
    end
  end

  context ".private_host?" do
    should "flag local names and private, loopback, link-local and reserved literals" do
      %w[localhost foo.localhost printer.local db.internal 127.0.0.1 10.1.2.3 172.16.0.1 192.168.0.1
         169.254.169.254 0.0.0.0 0.1.2.3 100.64.0.1 100.127.255.254 198.18.0.1 224.0.0.1 255.255.255.255
         ::1 [::1] :: fd00::1 fe80::1].each do |host|
        assert FeedbackExchange::HostGuard.private_host?(host), "expected #{host} to be private"
      end
    end

    should "flag IPv4 addresses wrapped in IPv6" do
      %w[::ffff:127.0.0.1 ::ffff:10.0.0.1 ::127.0.0.1 [::ffff:169.254.169.254] ::ffff:7f00:1].each do |host|
        assert FeedbackExchange::HostGuard.private_host?(host), "expected #{host} to be private"
      end
    end

    should "pass public names and addresses" do
      %w[chip.example.com 93.184.216.34 100.63.255.255 100.128.0.1 2606:2800:220:1::1 ::ffff:93.184.216.34].each do |host|
        assert_not FeedbackExchange::HostGuard.private_host?(host), "expected #{host} to be public"
      end
    end
  end

  context ".check!" do
    should "refuse every non-canonical loopback form before resolving anything" do
      Addrinfo.stub(:getaddrinfo, ->(*) { flunk "must not resolve a non-canonical host" }) do
        NON_CANONICAL_LOOPBACKS.each { |host| assert refused?("https://#{host}/x"), "expected #{host} to be refused" }
      end
    end

    should "refuse private literals, including IPv4 wrapped in IPv6" do
      %w[https://127.0.0.1 https://10.0.0.5 https://100.64.0.1 https://[::1] https://[::ffff:127.0.0.1]
         https://[::127.0.0.1] https://localhost https://db.internal].each do |url|
        assert refused?(url), "expected #{url} to be refused"
      end
    end

    should "refuse a name that resolves to a private address, whatever else it resolves to" do
      resolved = [ Addrinfo.ip("93.184.216.34"), Addrinfo.ip("10.0.0.9") ]
      Addrinfo.stub(:getaddrinfo, resolved) { assert refused?("https://x.example.com") }
    end

    should "refuse a name that resolves to IPv4 wrapped in IPv6, or to carrier-grade NAT" do
      [ "::ffff:127.0.0.1", "100.64.0.1", "0.0.0.0" ].each do |address|
        Addrinfo.stub(:getaddrinfo, [ Addrinfo.ip(address) ]) { assert refused?("https://x.example.com"), "expected #{address}" }
      end
    end

    should "say why it refused" do
      error = assert_raises(FeedbackExchange::Errors::AddressRefused) { FeedbackExchange::HostGuard.check!("https://127.1/x") }
      assert_match(/plain hostname or IP address/, error.message)

      error = assert_raises(FeedbackExchange::Errors::AddressRefused) { FeedbackExchange::HostGuard.check!("https://10.0.0.5/x") }
      assert_match(/private network address/, error.message)
    end

    should "return the public address it accepted, for the connection to use" do
      Addrinfo.stub(:getaddrinfo, [ Addrinfo.ip("93.184.216.34") ]) do
        assert_equal "93.184.216.34", FeedbackExchange::HostGuard.check!("https://x.example.com")
      end
    end

    should "return an IP literal as it is" do
      assert_equal "93.184.216.34", FeedbackExchange::HostGuard.check!("https://93.184.216.34/x")
    end

    should "refuse a name that does not resolve, so a later answer cannot choose the destination" do
      Addrinfo.stub(:getaddrinfo, ->(*) { raise SocketError, "nope" }) do
        error = assert_raises(FeedbackExchange::Errors::AddressRefused) { FeedbackExchange::HostGuard.check!("https://nowhere.example.com") }
        assert_match(/does not resolve/, error.message)
      end

      Addrinfo.stub(:getaddrinfo, []) { assert refused?("https://nowhere.example.com") }
    end

    should "stand down in development" do
      Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("development")) do
        assert_nil FeedbackExchange::HostGuard.check!("http://localhost:4000")
        assert_nil FeedbackExchange::HostGuard.check!("http://127.1:4000")
      end
    end
  end
end
