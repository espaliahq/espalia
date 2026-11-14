# frozen_string_literal: true

require "test_helper"

class Tenant::ExchangeRatesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin,
                           person: create(:person, tenant: @tenant, name: "Ada Admin"))
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member, org_graph_editor: true)
    end
  end

  def rate_params(overrides = {})
    { exchange_rate: { from_currency: "nzd", to_currency: "AUD", rate: " 0.92 ", applies_from: "2026-07-01" }.merge(overrides) }
  end

  def stored_rate
    ActsAsTenant.with_tenant(@tenant) do
      ExchangeRate.create!(from_currency: "NZD", to_currency: "AUD", rate: BigDecimal("0.9"), applies_from: Date.new(2026, 7, 1))
    end
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "show the panel beside the bands, with no reference currency yet" do
      get tenant_pay_bands_path

      assert_response :success
      assert_select "#exchange-rates h2", text: "Exchange rates"
      assert_includes response.body, "Not set yet."
      assert_includes response.body, "No rates yet."
    end

    should "set the reference currency and default a new rate's To currency to it" do
      patch tenant_reference_currency_path, params: { reference_currency: { currency: " nzd " } }

      assert_redirected_to tenant_pay_bands_path
      follow_redirect!
      assert_includes response.body, "Reports now total in NZD."
      assert_includes response.body, "Changed by Ada Admin"
      assert_select "#reference-currency[value='NZD']"
      assert_select "#exchange-rate-to[value='NZD']"
    end

    should "show a refused reference currency again with what was typed" do
      patch tenant_reference_currency_path, params: { reference_currency: { currency: "XYZ" } }

      assert_response :unprocessable_content
      assert_includes response.body, "The reference currency could not be set"
      assert_select "#reference-currency[value='XYZ']"
    end

    should "add a rate, dropping the spaces typed around it" do
      post tenant_exchange_rates_path, params: rate_params

      assert_redirected_to tenant_pay_bands_path
      rate = ActsAsTenant.with_tenant(@tenant) { ExchangeRate.sole }
      assert_equal [ "NZD", BigDecimal("0.92"), @admin_user ], [ rate.from_currency, rate.rate, rate.updated_by ]

      follow_redirect!
      assert_includes response.body, "Rate added for NZD to AUD from 1 Jul 2026."
      assert_select "#exchange-rate-#{rate.id}", text: /1 NZD = 0.92 AUD · from 1 Jul 2026/
    end

    should "show a refused rate again with what was typed, never the rate in the message" do
      stored_rate
      post tenant_exchange_rates_path, params: rate_params(rate: "0.77")

      assert_response :unprocessable_content
      assert_includes flash[:alert], "already a rate from NZD to AUD applying from 2026-07-01"
      assert_no_match(/0\.77/, flash[:alert])
      assert_select "#exchange-rate-rate[value='0.77']"
    end

    should "change only a rate's value" do
      rate = stored_rate

      get edit_tenant_exchange_rate_path(rate)
      assert_response :success
      assert_select "#exchange-rate-rate[value='0.9']"

      patch tenant_exchange_rate_path(rate), params: rate_params(rate: "0.95", from_currency: "USD")

      assert_redirected_to tenant_pay_bands_path
      rate.reload
      assert_equal [ "NZD", BigDecimal("0.95") ], [ rate.from_currency, rate.rate ]
    end

    should "show a refused change again with what was typed" do
      rate = stored_rate

      patch tenant_exchange_rate_path(rate), params: rate_params(rate: "-1")

      assert_response :unprocessable_content
      assert_select "#exchange-rate-rate[value='-1']"
      assert_equal BigDecimal("0.9"), rate.reload.rate
    end

    should "remove a rate" do
      delete tenant_exchange_rate_path(stored_rate)

      assert_redirected_to tenant_pay_bands_path
      assert_equal 0, ActsAsTenant.with_tenant(@tenant) { ExchangeRate.count }
    end

    should "answer 404 for a rate the tenant doesn't hold" do
      get edit_tenant_exchange_rate_path(SecureRandom.uuid_v7)

      assert_response :not_found
    end
  end

  context "as a member, even an Org Graph editor" do
    setup { sign_in @member_user }

    should "refuse every rate and reference currency action" do
      rate = stored_rate

      post tenant_exchange_rates_path, params: rate_params(applies_from: "2026-08-01")
      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
      get edit_tenant_exchange_rate_path(rate)
      assert_redirected_to root_path
      patch tenant_exchange_rate_path(rate), params: rate_params(rate: "1")
      delete tenant_exchange_rate_path(rate)
      patch tenant_reference_currency_path, params: { reference_currency: { currency: "NZD" } }

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal [ 1, BigDecimal("0.9") ], [ ExchangeRate.count, ExchangeRate.sole.rate ]
        assert_equal 0, ReferenceCurrency.count
      end
    end
  end
end
