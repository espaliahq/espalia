# frozen_string_literal: true

require "test_helper"

class Tenant::PayBandsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin,
                           person: create(:person, tenant: @tenant, name: "Ada Admin"))
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member, org_graph_editor: true)
      role = create(:framework_role, tenant: @tenant)
      @level = create(:framework_level, tenant: @tenant, role_id: role.role_id, code: "E2", title: "Engineer II")
    end
  end

  def band_params(overrides = {})
    { pay_band: { level_id: @level.level_id, location: "Fixtureland", currency: "aud", period: "year",
                  minimum: "100,000", midpoint: "120,000", maximum: "140,000" }.merge(overrides) }
  end

  def stored_band(**attrs)
    ActsAsTenant.with_tenant(@tenant) do
      PayBand.create!(level: @level, location: "Testonia",
                      currency: "NZD", period: "month", minimum: 8000, midpoint: 9000, maximum: 10_000, **attrs)
    end
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "show an empty page with the level picker" do
      get tenant_pay_bands_path

      assert_response :success
      assert_includes response.body, "No pay bands yet"
      assert_select "#pay-band-level optgroup[label='Software Engineer'] option", text: "E2 Engineer II"
    end

    should "add a band, reading the separators a person types" do
      post tenant_pay_bands_path, params: band_params

      assert_redirected_to tenant_pay_bands_path
      band = ActsAsTenant.with_tenant(@tenant) { PayBand.sole }
      assert_equal [ "AUD", BigDecimal("100000"), @admin_user ], [ band.currency, band.minimum, band.updated_by ]

      follow_redirect!
      assert_includes response.body, "Band added for Software Engineer, E2 Engineer II, Fixtureland."
      assert_includes response.body, "AUD 100,000 to 140,000 a year"
      assert_includes response.body, "Changed by Ada Admin"
    end

    should "show a refused band again with what was typed" do
      post tenant_pay_bands_path, params: band_params(minimum: "130000")

      assert_response :unprocessable_content
      assert_includes response.body, "The band could not be added: The minimum can"
      assert_select "#pay-band-minimum[value='130000']"
      assert_select "#pay-band-location[value='Fixtureland']"
      assert_equal 0, ActsAsTenant.with_tenant(@tenant) { PayBand.count }
    end

    should "refuse a decimal comma rather than read it as a thousands separator" do
      post tenant_pay_bands_path, params: band_params(minimum: "52,50", midpoint: "60,50", maximum: "70,50")

      assert_response :unprocessable_content
      assert_select "#pay-band-minimum[value='52,50']"
      assert_equal 0, ActsAsTenant.with_tenant(@tenant) { PayBand.count }
    end

    should "change a band's figures and keep its key" do
      band = stored_band

      get edit_tenant_pay_band_path(band)
      assert_response :success
      assert_select "#pay-band-midpoint[value='9000.00']"

      patch tenant_pay_band_path(band), params: band_params(minimum: "8500", location: "Elsewhere")

      assert_redirected_to tenant_pay_bands_path
      band.reload
      assert_equal [ "Testonia", "AUD", "year", BigDecimal("8500") ], [ band.location, band.currency, band.period, band.minimum ]
    end

    should "show a refused change again with what was typed" do
      band = stored_band

      patch tenant_pay_band_path(band), params: band_params(maximum: "1")

      assert_response :unprocessable_content
      assert_select "#pay-band-maximum[value='1']"
      assert_equal BigDecimal("10000"), band.reload.maximum
    end

    should "remove a band" do
      band = stored_band

      delete tenant_pay_band_path(band)

      assert_redirected_to tenant_pay_bands_path
      assert_equal 0, ActsAsTenant.with_tenant(@tenant) { PayBand.count }
    end

    should "give two roles that share a name a card each" do
      stored_band
      other = ActsAsTenant.with_tenant(@tenant) do
        role = create(:framework_role, tenant: @tenant)
        create(:framework_level, tenant: @tenant, role_id: role.role_id, code: "E2", title: "Engineer II")
      end
      stored_band(level: other)

      get tenant_pay_bands_path

      assert_select "[id^='pay-bands-'] h2", text: "Software Engineer", count: 2
    end

    should "answer 404 for a band the tenant doesn't hold" do
      get edit_tenant_pay_band_path(SecureRandom.uuid_v7)

      assert_response :not_found
    end
  end

  context "as a member, even an Org Graph editor" do
    setup { sign_in @member_user }

    should "refuse every pay band action" do
      band = stored_band

      get tenant_pay_bands_path
      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]

      post tenant_pay_bands_path, params: band_params
      get edit_tenant_pay_band_path(band)
      assert_redirected_to root_path
      patch tenant_pay_band_path(band), params: band_params(minimum: "1")
      delete tenant_pay_band_path(band)

      assert_equal [ 1, BigDecimal("8000") ], ActsAsTenant.with_tenant(@tenant) { [ PayBand.count, PayBand.sole.minimum ] }
    end
  end
end
