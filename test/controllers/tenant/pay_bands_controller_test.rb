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
      @family = create(:framework_role_family, tenant: @tenant, name: "Engineering")
      @role = create(:framework_role, tenant: @tenant, role_family_id: @family.role_family_id)
      @level = create(:framework_level, tenant: @tenant, role_id: @role.role_id, ordinal: 2, code: "E2", title: "Engineer II")
    end
  end

  def band_params(overrides = {})
    { pay_band: { reach: "role:#{@role.role_id}", level_ordinal: "2", location: "Fixtureland", currency: "aud", period: "year",
                  minimum: "100,000", midpoint: "120,000", maximum: "140,000" }.merge(overrides) }
  end

  def stored_band(**attrs)
    ActsAsTenant.with_tenant(@tenant) do
      PayBand.create!(level: @level, location: "Testonia",
                      currency: "NZD", period: "month", minimum: 8000, midpoint: 9000, maximum: 10_000, **attrs)
    end
  end

  def positions = ActsAsTenant.with_tenant(@tenant) { PayBand.order(:position).pluck(:location) }

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "show an empty page with the pickers for who and which level" do
      get tenant_pay_bands_path

      assert_response :success
      assert_includes response.body, "No pay bands yet"
      assert_select "#pay-band-reach option[value='']", text: "Every role"
      assert_select "#pay-band-reach optgroup[label='Engineering'] option[value='family:#{@family.role_family_id}']",
                    text: "Every role in Engineering"
      assert_select "#pay-band-reach optgroup[label='Engineering'] option[value='role:#{@role.role_id}']", text: "Software Engineer"
      assert_select "#pay-band-level-ordinal option[value='2']", text: "Level 2"
    end

    should "add a band, reading the separators a person types" do
      post tenant_pay_bands_path, params: band_params

      assert_redirected_to tenant_pay_bands_path
      band = ActsAsTenant.with_tenant(@tenant) { PayBand.sole }
      assert_equal [ "AUD", BigDecimal("100000"), @admin_user ], [ band.currency, band.minimum, band.updated_by ]

      follow_redirect!
      assert_includes response.body, "Band added for Software Engineer, E2 Engineer II, Fixtureland at 1 in the list."
      assert_includes response.body, "AUD 100,000 to 140,000 a year"
      assert_includes response.body, "Changed by Ada Admin"
    end

    should "show a refused band again with what was typed" do
      post tenant_pay_bands_path, params: band_params(minimum: "130000")

      assert_response :unprocessable_content
      assert_includes response.body, "The band could not be added: The minimum can"
      assert_select "#pay-band-minimum[value='130000']"
      assert_select "#pay-band-location[value='Fixtureland']"
      assert_select "#pay-band-reach option[selected][value='role:#{@role.role_id}']"
      assert_select "#pay-band-level-ordinal option[selected][value='2']"
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
      assert_equal "Band removed for Software Engineer, E2 Engineer II, Testonia.", flash[:notice]
      assert_equal 0, ActsAsTenant.with_tenant(@tenant) { PayBand.count }
    end

    should "add a band for every role, or for a role family, below the bands wider than it" do
      post tenant_pay_bands_path, params: band_params(reach: "", level_ordinal: "", location: "")
      post tenant_pay_bands_path, params: band_params(location: "Narrowland")
      post tenant_pay_bands_path, params: band_params(reach: "family:#{@family.role_family_id}", level_ordinal: "")

      assert_equal "Band added for Every role in Engineering, Every level, Fixtureland at 2 in the list.", flash[:notice]
      assert_equal [ "", "Fixtureland", "Narrowland" ], positions
    end

    should "list the bands in order, flagging one that never has the last word" do
      role_band = stored_band(location: "Alpha")
      ActsAsTenant.with_tenant(@tenant) do
        family_band = PayBand.new(location: "Alpha", currency: "AUD", period: "year", minimum: 1, midpoint: 2, maximum: 3)
                             .tap { it.match_on(role_family: @family) }
        family_band.save!
        PayBand.reorder!([ role_band.id, family_band.id ])
      end

      get tenant_pay_bands_path

      assert_select "#pay-bands-order li", count: 2
      assert_select "#pay-bands-order li:first-child", text: /1\.\s*Software Engineer, E2 Engineer II/
      assert_select "#pay-band-shadowed-#{role_band.id}", text: "Never used"
      assert_select "#pay-bands-order li:last-child", text: /2\.\s*Every role in Engineering, Every level/
      assert_select "[id^='pay-band-shadowed-']", count: 1
      assert_select "#pay-band-up-#{role_band.id}", count: 0
      assert_select "#pay-band-down-#{role_band.id}[form=pay-bands-move-form]", count: 1
      assert_select "input[name='from_pay_band_ids[]']", count: 2, message: "the order the page shows, once, not once per button"
    end

    should "move a band up or down a place, and save a dragged order" do
      first = stored_band(location: "Alpha")
      second = stored_band(location: "Beta")
      third = stored_band(location: "Gamma")

      patch reorder_tenant_pay_bands_path, params: { pay_band_id: third.id, direction: "up", from_pay_band_ids: [ first.id, second.id, third.id ] }

      assert_redirected_to tenant_pay_bands_path
      assert_equal "Moved the band for Software Engineer, E2 Engineer II, Gamma to 2 in the list.", flash[:notice]
      assert_equal %w[Alpha Gamma Beta], positions

      patch reorder_tenant_pay_bands_path, params: { pay_band_id: first.id, direction: "up", from_pay_band_ids: [ first.id, third.id, second.id ] }
      assert_equal %w[Alpha Gamma Beta], positions

      patch reorder_tenant_pay_bands_path, params: { pay_band_ids: [ second.id, third.id, first.id ], from_pay_band_ids: [ first.id, third.id, second.id ] }
      assert_equal "Saved the new order.", flash[:notice]
      assert_equal %w[Beta Gamma Alpha], positions
    end

    should "move nothing from a page the list has changed under" do
      first = stored_band(location: "Alpha")
      last = stored_band(location: "Beta")
      stale = "The list changed since you opened it, so nothing moved. Here it is as it stands."

      patch reorder_tenant_pay_bands_path, params: { pay_band_ids: [ first.id ] }
      assert_equal stale, flash[:alert]

      patch reorder_tenant_pay_bands_path, params: { pay_band_id: SecureRandom.uuid_v7, direction: "down", from_pay_band_ids: [ first.id, last.id ] }
      assert_equal stale, flash[:alert]

      patch reorder_tenant_pay_bands_path, params: { pay_band_id: last.id, direction: "down", from_pay_band_ids: [ first.id, last.id ] }
      assert_equal stale, flash[:alert]

      patch reorder_tenant_pay_bands_path, params: { pay_band_id: last.id, direction: "up" }
      assert_equal stale, flash[:alert], "a button that doesn't say what order it saw"

      patch reorder_tenant_pay_bands_path, params: { pay_band_ids: [ last.id, first.id ], from_pay_band_ids: [ last.id, first.id ] }
      assert_equal stale, flash[:alert]
      assert_equal %w[Alpha Beta], positions
    end

    should "move nothing from a button on a page showing an order another admin has since changed" do
      alpha = stored_band(location: "Alpha")
      beta = stored_band(location: "Beta")
      gamma = stored_band(location: "Gamma")

      patch reorder_tenant_pay_bands_path, params: { pay_band_id: beta.id, direction: "down", from_pay_band_ids: [ beta.id, alpha.id, gamma.id ] }

      assert_equal "The list changed since you opened it, so nothing moved. Here it is as it stands.", flash[:alert]
      assert_equal %w[Alpha Beta Gamma], positions
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
      patch reorder_tenant_pay_bands_path, params: { pay_band_id: band.id, direction: "down" }
      assert_redirected_to root_path
      delete tenant_pay_band_path(band)

      assert_equal [ 1, BigDecimal("8000") ], ActsAsTenant.with_tenant(@tenant) { [ PayBand.count, PayBand.sole.minimum ] }
    end
  end
end
