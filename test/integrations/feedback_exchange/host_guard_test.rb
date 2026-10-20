# frozen_string_literal: true

require "test_helper"

class FeedbackExchange::HostGuardTest < ActiveSupport::TestCase
  context ".private_host?" do
    should "flag local names and private, loopback and link-local literals" do
      %w[localhost foo.localhost printer.local db.internal 127.0.0.1 10.1.2.3 172.16.0.1 192.168.0.1
         169.254.169.254 0.0.0.0 ::1 [::1] fd00::1 ::ffff:10.0.0.1].each do |host|
        assert FeedbackExchange::HostGuard.private_host?(host), "expected #{host} to be private"
      end
    end

    should "pass public names and addresses" do
      %w[chip.example.com 93.184.216.34 2606:2800:220:1::1].each do |host|
        assert_not FeedbackExchange::HostGuard.private_host?(host), "expected #{host} to be public"
      end
    end
  end

  context ".check!" do
    should "refuse a name that resolves to a private address" do
      Resolv.stub(:getaddresses, [ "93.184.216.34", "10.0.0.9" ]) do
        assert_raises(FeedbackExchange::Errors::ApiError) { FeedbackExchange::HostGuard.check!("https://x.example.com") }
      end
    end

    should "pass a name that resolves to public addresses" do
      Resolv.stub(:getaddresses, [ "93.184.216.34" ]) do
        assert_nil FeedbackExchange::HostGuard.check!("https://x.example.com")
      end
    end

    should "stand down in development" do
      Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("development")) do
        assert_nil FeedbackExchange::HostGuard.check!("http://localhost:4000")
      end
    end
  end
end
