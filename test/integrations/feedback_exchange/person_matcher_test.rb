# frozen_string_literal: true

require "test_helper"

class FeedbackExchange::PersonMatcherTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant, :with_hibob_config)
    ActsAsTenant.current_tenant = @tenant
    @priya = create(:person, tenant: @tenant, email: "Priya@MeAndU.com", external_id: "3141", hris_source: "hibob")
    @alex = create(:person, tenant: @tenant, email: "alex@meandu.com")
    @matcher = FeedbackExchange::PersonMatcher.new(@tenant)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  should "prefer the id from the tenant's HRIS over the email" do
    found = @matcher.match({ "email" => "alex@meandu.com", "external_ids" => { "hibob" => "3141" } })
    assert_equal @priya, found
  end

  should "fall back to the email, lower-cased" do
    assert_equal @priya, @matcher.match({ "email" => " PRIYA@meandu.com ", "external_ids" => { "hibob" => "9999" } })
  end

  should "ignore ids keyed by a system this tenant does not sync from" do
    assert_equal @alex, @matcher.match({ "email" => "alex@meandu.com", "external_ids" => { "slack" => "3141" } })
  end

  should "return nil for an unknown person, never create one" do
    assert_no_difference -> { Person.count } do
      assert_nil @matcher.match({ "email" => "nobody@meandu.com" })
    end
  end

  should "return nil for a missing person" do
    assert_nil @matcher.match(nil)
  end

  should "not reach into another tenant" do
    other = create(:tenant)
    ActsAsTenant.with_tenant(other) { create(:person, tenant: other, email: "zed@meandu.com") }
    assert_nil @matcher.match({ "email" => "zed@meandu.com" })
  end
end
