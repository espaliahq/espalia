# frozen_string_literal: true

require "test_helper"

class Operations::Tenants::PayBandsTest < ActiveSupport::TestCase
  FIGURES = { minimum: "100000", midpoint: "120000", maximum: "140000" }.freeze

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant, name: "Ada Admin"))
      @member = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant))
      @editor = create(:tenant_user, tenant: @tenant, role: :member, org_graph_editor: true,
                                     person: create(:person, tenant: @tenant))
      role = create(:framework_role, tenant: @tenant)
      @level = create(:framework_level, tenant: @tenant, role_id: role.role_id, code: "E2", title: "Engineer II")
    end
  end

  def context(account) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) { "Operations::Tenants::#{operation}".constantize.call(context: context(as), params:) }
  end

  def add(**params)
    call(:AddPayBand, level_id: @level.level_id, location: "Fixtureland", currency: "AUD", period: "year", **FIGURES, **params)
  end

  should "add a band, list it, change it and remove it" do
    added = add

    assert_equal "Software Engineer, E2 Engineer II", added[:level]
    assert_equal "Fixtureland", added[:location]
    assert_equal "100000.00", added[:minimum]
    assert_equal "Ada Admin", added[:updated_by]
    assert added[:in_framework]

    assert_equal [ added[:pay_band_id] ], call(:PayBands)[:pay_bands].pluck(:pay_band_id)

    changed = call(:ChangePayBand, pay_band_id: added[:pay_band_id], currency: "NZD", period: "month",
                                   minimum: "8000", midpoint: "9000.5", maximum: "10000")
    assert_equal [ "NZD", "month", "9000.50" ], changed.values_at(:currency, :period, :midpoint)

    removed = call(:RemovePayBand, pay_band_id: added[:pay_band_id])
    assert_equal "Fixtureland", removed[:location]
    assert_empty call(:PayBands)[:pay_bands]
  end

  should "keep a band whose level has left the framework, marked so" do
    added = add
    ActsAsTenant.with_tenant(@tenant) { @level.destroy! }

    listed = call(:PayBands)[:pay_bands].sole
    assert_equal added[:pay_band_id], listed[:pay_band_id]
    assert_equal "Software Engineer, E2 Engineer II", listed[:level]
    assert_not listed[:in_framework]
  end

  should "name a band as the framework names its level now, and keep that name on a change" do
    added = add
    ActsAsTenant.with_tenant(@tenant) { FrameworkState::Role.find_by(role_id: @level.role_id).update!(name: "Platform Engineer") }

    assert_equal "Platform Engineer, E2 Engineer II", call(:PayBands)[:pay_bands].sole[:level]

    call(:ChangePayBand, pay_band_id: added[:pay_band_id], currency: "AUD", period: "year", **FIGURES)
    ActsAsTenant.with_tenant(@tenant) { @level.destroy! }
    assert_equal "Platform Engineer, E2 Engineer II", call(:PayBands)[:pay_bands].sole[:level]
  end

  should "list the any-location band first, then the countries" do
    add(location: "Testonia")
    add(location: "")

    assert_equal [ nil, "Testonia" ], call(:PayBands)[:pay_bands].pluck(:location)
  end

  should "read a band with no location as the band for any location" do
    added = call(:AddPayBand, level_id: @level.level_id, currency: "AUD", period: "year", **FIGURES)

    assert_nil added[:location]
  end

  should "refuse a level outside the framework" do
    error = assert_raises(Operations::Base::ParameterError) { add(level_id: SecureRandom.uuid_v7) }

    assert_equal "There is no such level in the framework", error.message
  end

  should "never repeat a figure in a refusal" do
    errors = [
      -> { add(minimum: "999999", midpoint: "888888") },
      -> { add(maximum: "77777.777") },
      -> { add(currency: "DOLLARS", minimum: "66666") }
    ].map { assert_raises(Operations::Base::ParameterError, &it).message }

    errors.each { |message| assert_no_match(/999|888|777|666|100|120|140/, message) }
    assert_match(/minimum can't be above the midpoint/, errors.first)
  end

  should "refuse a second band for the same level and location" do
    add
    error = assert_raises(Operations::Base::ParameterError) { add(location: " fixtureland") }

    assert_match(/already a band for this level in/, error.message)
  end

  should "refuse the second of two adds that race past the check" do
    add
    racing = ActsAsTenant.with_tenant(@tenant) do
      PayBand.new(tenant: @tenant, level: @level, location: "Fixtureland",
                  currency: "AUD", period: "year", minimum: 1, midpoint: 2, maximum: 3)
    end
    racing.define_singleton_method(:one_band_per_level_and_location) { nil }

    PayBand.stub(:new, racing) do
      error = assert_raises(Operations::Base::ParameterError) { add }

      assert_equal "There is already a band for this level in Fixtureland", error.message
    end
  end

  should "refuse a band this tenant doesn't hold" do
    assert_raises(Operations::Base::ParameterError) { call(:RemovePayBand, pay_band_id: SecureRandom.uuid_v7) }
  end

  should "leave pay bands to tenant admins, even an Org Graph editor" do
    added = add

    [ @member, @editor ].each do |account|
      assert_raises(Pundit::NotAuthorizedError) { call(:PayBands, as: account) }
      assert_raises(Pundit::NotAuthorizedError) { add(as: account, location: "Testonia") }
      assert_raises(Pundit::NotAuthorizedError) { call(:RemovePayBand, as: account, pay_band_id: added[:pay_band_id]) }
    end
    assert_equal 1, ActsAsTenant.with_tenant(@tenant) { PayBand.count }
  end

  should "not reach another tenant's bands" do
    added = add
    other = create(:tenant)
    outsider = ActsAsTenant.with_tenant(other) { create(:tenant_user, tenant: other, role: :admin, person: create(:person, tenant: other)) }

    ActsAsTenant.with_tenant(other) do
      assert_empty Operations::Tenants::PayBands.call(context: context(outsider), params: {})[:pay_bands]
      assert_raises(Operations::Base::ParameterError) do
        Operations::Tenants::RemovePayBand.call(context: context(outsider), params: { pay_band_id: added[:pay_band_id] })
      end
    end
  end
end
