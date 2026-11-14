# frozen_string_literal: true

require "test_helper"

class ReferenceCurrencyTest < ActiveSupport::TestCase
  setup { ActsAsTenant.current_tenant = create(:tenant) }

  teardown { ActsAsTenant.current_tenant = nil }

  should "keep an upper-case ISO 4217 code" do
    assert_equal "AUD", ReferenceCurrency.new(currency: " aud ").tap(&:valid?).currency
    assert_not ReferenceCurrency.new(currency: "XYZ").valid?
  end

  should "be the tenant's own, and unset until one is chosen" do
    assert_nil ReferenceCurrency.current

    ReferenceCurrency.create!(currency: "NZD")
    assert_equal "NZD", ReferenceCurrency.current.currency
    ActsAsTenant.with_tenant(create(:tenant)) { assert_nil ReferenceCurrency.current }
  end
end
