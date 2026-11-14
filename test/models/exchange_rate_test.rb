# frozen_string_literal: true

require "test_helper"

class ExchangeRateTest < ActiveSupport::TestCase
  JULY = Date.new(2026, 7, 1)

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def rate(from: "NZD", to: "AUD", rate: "0.5", applies_from: JULY)
    ExchangeRate.new(from_currency: from, to_currency: to, rate:, applies_from:)
  end

  def convert(amount, from: "NZD", to: "AUD", on: JULY) = ExchangeRate.convert(amount, from:, to:, on:)

  should "convert with the pair's rate, and the reverse pair's inverse" do
    rate.save!

    assert_equal BigDecimal("50"), convert(100)
    assert_equal BigDecimal("200"), convert(100, from: "AUD", to: "NZD")
  end

  should "use the rate in force on the date, so each period converts at its own" do
    rate.save!
    rate(rate: "0.6", applies_from: JULY.next_month).save!

    assert_equal BigDecimal("50"), convert(100, on: JULY.end_of_month)
    assert_equal BigDecimal("60"), convert(100, on: JULY.next_month)
  end

  should "prefer whichever direction applies from later, and the pair's own should two adds race to one date" do
    rate.save!
    rate(from: "AUD", to: "NZD", rate: "4", applies_from: JULY.next_month).save!

    assert_equal BigDecimal("25"), convert(100, on: JULY.next_month)

    rate(rate: "0.2", applies_from: JULY.next_month).save!(validate: false)
    assert_equal BigDecimal("20"), convert(100, on: JULY.next_month)
  end

  should "name the pair and the date when no rate is in force, never converting at 1.0" do
    rate.save!

    error = assert_raises(ExchangeRate::MissingRate) { convert(100, on: JULY.prev_day) }
    assert_equal "There is no exchange rate from NZD to AUD in force on 2026-06-30", error.message
    assert_raises(ExchangeRate::MissingRate) { convert(100, from: "NZD", to: "USD") }
  end

  should "not chain through a third currency" do
    rate.save!
    rate(from: "AUD", to: "USD", rate: "0.7").save!

    assert_raises(ExchangeRate::MissingRate) { convert(100, to: "USD") }
  end

  should "refuse to convert without a tenant or a date, rather than read every rate there is" do
    rate.save!

    ActsAsTenant.without_tenant { assert_raises(ArgumentError) { convert(100) } }
    assert_raises(ArgumentError) { convert(100, on: nil) }
    assert_raises(ArgumentError) { convert(100, on: "2026-07-01") }
  end

  should "convert a currency to itself without a rate" do
    assert_equal BigDecimal("100"), convert(100, from: "aud", to: "AUD")
  end

  should "not read another tenant's rates" do
    rate.save!

    ActsAsTenant.with_tenant(create(:tenant)) { assert_raises(ExchangeRate::MissingRate) { convert(100) } }
  end

  should "keep one rate per pair and date" do
    rate.save!
    duplicate = rate(from: "nzd", rate: "0.7")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:base], "There is already a rate between NZD and AUD applying from 2026-07-01"
  end

  should "refuse the reverse pair on the same date, which would contradict the rate" do
    rate.save!
    reverse = rate(from: "AUD", to: "NZD", rate: "4")

    assert_not reverse.valid?
    assert_includes reverse.errors[:base], "There is already a rate between AUD and NZD applying from 2026-07-01"
    assert rate(from: "AUD", to: "NZD", rate: "2", applies_from: JULY.next_day).valid?
  end

  should "refuse a rate that isn't positive, a currency ISO doesn't list, or one currency twice" do
    assert_not rate(rate: "0").valid?
    assert_not rate(rate: "-1").valid?
    assert_not rate(from: "XYZ").valid?
    assert_not rate(to: "NZD").valid?
    assert_not rate(applies_from: nil).valid?
  end

  should "give the rate without trailing zeros" do
    assert_equal "0.92", rate(rate: "0.920000").figure
    assert_equal "2", rate(rate: "2").figure
  end
end
