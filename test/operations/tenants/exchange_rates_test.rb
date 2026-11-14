# frozen_string_literal: true

require "test_helper"

class Operations::Tenants::ExchangeRatesTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant, name: "Ada Admin"))
      @member = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant))
      @editor = create(:tenant_user, tenant: @tenant, role: :member, org_graph_editor: true,
                                     person: create(:person, tenant: @tenant))
    end
  end

  def context(account) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) { "Operations::Tenants::#{operation}".constantize.call(context: context(as), params:) }
  end

  def add(**params)
    call(:AddExchangeRate, from_currency: "NZD", to_currency: "AUD", rate: "0.5", applies_from: "2026-07-01", **params)
  end

  should "add a rate, list it, correct it and remove it" do
    added = add

    assert_equal [ "NZD", "AUD", "0.5", "2026-07-01", "Ada Admin" ],
                 added.values_at(:from_currency, :to_currency, :rate, :applies_from, :updated_by)
    assert_equal [ added[:exchange_rate_id] ], call(:ExchangeRates)[:exchange_rates].pluck(:exchange_rate_id)

    changed = call(:ChangeExchangeRate, exchange_rate_id: added[:exchange_rate_id], rate: "0.55")
    assert_equal [ "0.55", "2026-07-01" ], changed.values_at(:rate, :applies_from)

    removed = call(:RemoveExchangeRate, exchange_rate_id: added[:exchange_rate_id])
    assert_equal "NZD", removed[:from_currency]
    assert_empty call(:ExchangeRates)[:exchange_rates]
  end

  should "list each pair's rates newest first, and read one by id" do
    older = add
    add(rate: "0.6", applies_from: "2026-10-01")
    add(from_currency: "GBP", rate: "1.9")

    assert_equal [ %w[GBP 2026-07-01], %w[NZD 2026-10-01], %w[NZD 2026-07-01] ],
                 call(:ExchangeRates)[:exchange_rates].map { it.values_at(:from_currency, :applies_from) }
    assert_equal [ older[:exchange_rate_id] ],
                 call(:ExchangeRates, exchange_rate_id: older[:exchange_rate_id])[:exchange_rates].pluck(:exchange_rate_id)
  end

  should "set the reference currency, and say who set it" do
    assert_nil call(:ExchangeRates)[:reference_currency]

    call(:SetReferenceCurrency, currency: "aud")
    set = call(:SetReferenceCurrency, currency: "NZD")

    assert_equal [ "NZD", "Ada Admin" ], set.values_at(:currency, :updated_by)
    assert_equal "NZD", call(:ExchangeRates)[:reference_currency][:currency]
    assert_equal 1, ActsAsTenant.with_tenant(@tenant) { ReferenceCurrency.count }
  end

  should "refuse a currency ISO 4217 doesn't list, for a rate and for the reference" do
    assert_raises(Operations::Base::ParameterError) { add(to_currency: "XYZ") }
    error = assert_raises(Operations::Base::ParameterError) { call(:SetReferenceCurrency, currency: "XYZ") }

    assert_equal "Currency must be an ISO 4217 currency code, such as AUD", error.message
  end

  should "refuse a bad date, a second rate for the pair's date, and one currency twice" do
    assert_match(/applies_from must be a date/, assert_raises(Operations::Base::ParameterError) { add(applies_from: "July") }.message)
    add
    assert_match(/already a rate between NZD and AUD/, assert_raises(Operations::Base::ParameterError) { add(rate: "0.7") }.message)
    assert_raises(Operations::Base::ParameterError) { add(to_currency: "NZD") }
  end

  should "never repeat a rate in a refusal" do
    errors = [ -> { add(rate: "0") }, -> { add(rate: "7.1234567890123") }, -> { add(rate: "-3") },
               -> { add(rate: "4.4", to_currency: "XYZ") } ].map { assert_raises(Operations::Base::ParameterError, &it).message }

    errors.each { |message| assert_no_match(/\d\.\d|-3/, message) }
  end

  should "refuse a change to a rate removed after it was found" do
    added = add
    stale = ActsAsTenant.with_tenant(@tenant) { ExchangeRate.find(added[:exchange_rate_id]).tap { ExchangeRate.find(it.id).destroy! } }

    ExchangeRate.stub(:find_by, stale) do
      error = assert_raises(Operations::Base::ParameterError) { call(:ChangeExchangeRate, exchange_rate_id: stale.id, rate: "1") }

      assert_equal "There is no such exchange rate", error.message
    end
  end

  should "refuse a rate this tenant doesn't hold" do
    assert_raises(Operations::Base::ParameterError) { call(:ChangeExchangeRate, exchange_rate_id: SecureRandom.uuid_v7, rate: "1") }
  end

  should "leave exchange rates to tenant admins, even an Org Graph editor" do
    added = add

    [ @member, @editor ].each do |account|
      assert_raises(Pundit::NotAuthorizedError) { call(:ExchangeRates, as: account) }
      assert_raises(Pundit::NotAuthorizedError) { add(as: account, applies_from: "2026-08-01") }
      assert_raises(Pundit::NotAuthorizedError) { call(:SetReferenceCurrency, as: account, currency: "AUD") }
      assert_raises(Pundit::NotAuthorizedError) { call(:RemoveExchangeRate, as: account, exchange_rate_id: added[:exchange_rate_id]) }
    end
    assert_equal 1, ActsAsTenant.with_tenant(@tenant) { ExchangeRate.count }
  end

  should "not reach another tenant's rates" do
    added = add
    other = create(:tenant)
    outsider = ActsAsTenant.with_tenant(other) { create(:tenant_user, tenant: other, role: :admin, person: create(:person, tenant: other)) }

    ActsAsTenant.with_tenant(other) do
      assert_empty Operations::Tenants::ExchangeRates.call(context: context(outsider), params: {})[:exchange_rates]
      assert_raises(Operations::Base::ParameterError) do
        Operations::Tenants::RemoveExchangeRate.call(context: context(outsider), params: { exchange_rate_id: added[:exchange_rate_id] })
      end
    end
  end
end
