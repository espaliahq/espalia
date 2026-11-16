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
      @role = create(:framework_role, tenant: @tenant)
      @family = create(:framework_role_family, tenant: @tenant, role_family_id: @role.role_family_id, name: "Engineering")
      @level = create(:framework_level, tenant: @tenant, role_id: @role.role_id, ordinal: 2, code: "E2", title: "Engineer II")
    end
  end

  def context(account) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) { "Operations::Tenants::#{operation}".constantize.call(context: context(as), params:) }
  end

  def count_queries(&)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }
    ActiveRecord::Base.uncached { ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &) }
    count
  end

  def add(**params)
    call(:AddPayBand, level_id: @level.level_id, location: "Fixtureland", currency: "AUD", period: "year", **FIGURES, **params)
  end

  def entry(**params) = call(:AddPayBand, currency: "AUD", period: "year", **FIGURES, **params)

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
    assert_equal [ "Fixtureland", "Software Engineer", "E2 Engineer II" ], removed.values_at(:location, :role, :level_name)
    assert_empty call(:PayBands)[:pay_bands]
  end

  should "read one band by id, naming who changed it in one query for every band" do
    added = add
    add(location: "Testonia")

    assert_equal [ added[:pay_band_id] ], call(:PayBands, pay_band_id: added[:pay_band_id])[:pay_bands].pluck(:pay_band_id)
    queries = count_queries { call(:PayBands) }
    add(location: "Elsewhere")
    assert_equal queries, count_queries { call(:PayBands) }
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

  should "report a band made from a level by that level, with the number the framework gives it now" do
    added = add
    ActsAsTenant.with_tenant(@tenant) { @level.update_columns(ordinal: 5) }
    band = call(:PayBands)[:pay_bands].sole

    assert_equal({ level_id: @level.level_id, location: "Fixtureland" }, added[:matcher])
    assert_equal({ level_id: @level.level_id, location: "Fixtureland" }, band[:matcher])
    assert_equal [ 5, @role.role_id ], band.values_at(:level_ordinal, :role_id)
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

  should "refuse a currency ISO 4217 doesn't list" do
    error = assert_raises(Operations::Base::ParameterError) { add(currency: "XYZ") }

    assert_equal "Currency must be an ISO 4217 currency code, such as AUD", error.message
  end

  should "refuse a second band for the same level and location" do
    add
    error = assert_raises(Operations::Base::ParameterError) { add(location: " fixtureland") }

    assert_match(/already a band for Software Engineer, E2 Engineer II in/, error.message)
  end

  should "refuse the second of two adds that race past the check" do
    add
    racing = ActsAsTenant.with_tenant(@tenant) do
      PayBand.new(tenant: @tenant, level: @level, location: "Fixtureland",
                  currency: "AUD", period: "year", minimum: 1, midpoint: 2, maximum: 3)
    end
    racing.define_singleton_method(:one_band_per_matcher) { nil }

    PayBand.stub(:new, racing) do
      error = assert_raises(Operations::Base::ParameterError) { add }

      assert_equal "There is already a band for Software Engineer, E2 Engineer II in Fixtureland", error.message
    end
  end

  should "write every field of a change, even onto a band changed since it was read" do
    added = add
    stale = ActsAsTenant.with_tenant(@tenant) { PayBand.find(added[:pay_band_id]) }
    ActsAsTenant.with_tenant(@tenant) { PayBand.find(added[:pay_band_id]).update!(currency: "NZD") }

    PayBand.stub(:find_by, stale) do
      call(:ChangePayBand, pay_band_id: added[:pay_band_id], currency: "AUD", period: "month",
                           minimum: "10", midpoint: "15", maximum: "20")
    end

    stored = ActsAsTenant.with_tenant(@tenant) { PayBand.find(added[:pay_band_id]) }
    assert_equal [ "AUD", "month", BigDecimal("15") ], [ stored.currency, stored.period, stored.midpoint ]
  end

  should "refuse a change to a band removed after it was found" do
    added = add
    stale = ActsAsTenant.with_tenant(@tenant) { PayBand.find(added[:pay_band_id]).tap { PayBand.find(it.id).destroy! } }

    PayBand.stub(:find_by, stale) do
      error = assert_raises(Operations::Base::ParameterError) do
        call(:ChangePayBand, pay_band_id: stale.id, currency: "AUD", period: "year", **FIGURES)
      end

      assert_equal "There is no such pay band", error.message
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

  context "the ordered list" do
    should "add a band for a role family, or for every role at a level number, each wider band ahead" do
      role_band = add(location: "")
      family = entry(role_family_id: @family.role_family_id, level_ordinal: 2)
      company = entry(level_ordinal: 2)

      assert_equal [ "Engineering, Level 2", { role_family_id: @family.role_family_id, level_ordinal: 2 } ], family.values_at(:level, :matcher)
      assert_equal [ "Every role, Level 2", { level_ordinal: 2 } ], company.values_at(:level, :matcher)
      assert_equal [ company, family, role_band ].pluck(:pay_band_id), call(:PayBands)[:pay_bands].pluck(:pay_band_id)
      assert_equal [ 1, 2, 3 ], call(:PayBands)[:pay_bands].pluck(:position)
    end

    should "flag a band a later band always overrules, and lift the flag once it moves below" do
      role_band = add(location: "")
      company = entry(level_ordinal: 2)
      assert_equal [ false, false ], call(:PayBands)[:pay_bands].pluck(:shadowed)

      reordered = call(:ReorderPayBands, pay_band_ids: [ role_band[:pay_band_id], company[:pay_band_id] ])[:pay_bands]
      assert_equal [ [ role_band[:pay_band_id], true ], [ company[:pay_band_id], false ] ], reordered.map { it.values_at(:pay_band_id, :shadowed) }
    end

    should "refuse a reorder that leaves out a band or names one twice" do
      first = add
      second = add(location: "Testonia")
      positions = call(:PayBands)[:pay_bands].pluck(:position)

      [ [ first[:pay_band_id] ], [ first[:pay_band_id], first[:pay_band_id] ], [ first[:pay_band_id], SecureRandom.uuid_v7 ] ].each do |ids|
        error = assert_raises(Operations::Base::ParameterError) { call(:ReorderPayBands, pay_band_ids: ids) }
        assert_equal "List every pay band once, as tenants_pay_bands lists them", error.message
      end
      assert_equal [ first, second ].pluck(:pay_band_id), call(:PayBands)[:pay_bands].pluck(:pay_band_id)
      assert_equal positions, call(:PayBands)[:pay_bands].pluck(:position)
    end

    should "refuse a reorder made from an order another change has moved since" do
      first = add
      second = add(location: "Testonia")
      read = [ first, second ].pluck(:pay_band_id)
      call(:ReorderPayBands, pay_band_ids: read.reverse)

      error = assert_raises(Operations::Base::ParameterError) do
        call(:ReorderPayBands, pay_band_ids: read.reverse, from_pay_band_ids: read)
      end
      assert_equal "The list has changed since you read it: read tenants_pay_bands again", error.message

      moved = call(:ReorderPayBands, pay_band_ids: read, from_pay_band_ids: read.reverse)[:pay_bands]
      assert_equal read, moved.pluck(:pay_band_id)
    end

    should "leave reordering to tenant admins" do
      added = add

      assert_raises(Pundit::NotAuthorizedError) { call(:ReorderPayBands, as: @editor, pay_band_ids: [ added[:pay_band_id] ]) }
    end

    should "change what a band matches on and keep its place" do
      added = add
      later = add(location: "Testonia")
      changed = call(:ChangePayBand, pay_band_id: added[:pay_band_id], role_family_id: @family.role_family_id,
                                     level_ordinal: 3, location: "", currency: "AUD", period: "year", **FIGURES)

      assert_equal [ 1, "Engineering, Level 3", nil, nil ], changed.values_at(:position, :level, :level_id, :location)
      assert_equal 2, call(:PayBands, pay_band_id: later[:pay_band_id])[:pay_bands].sole[:position]
    end

    should "refuse a matcher the framework can't hold" do
      {
        { role_id: @role.role_id, role_family_id: @family.role_family_id } => "A band matches on a role or a role family, not both: a role already names its family",
        { role_id: SecureRandom.uuid_v7 } => "There is no such role in the framework",
        { role_family_id: SecureRandom.uuid_v7 } => "There is no such role family in the framework",
        { level_id: @level.level_id, level_ordinal: 2 } => "Give level_id, or a role or role family and a level number, not both",
        { level_ordinal: 0 } => "level_ordinal must be 1 or more"
      }.each do |matcher, message|
        assert_equal message, assert_raises(Operations::Base::ParameterError) { entry(**matcher) }.message
      end
    end

    should "refuse a second band that matches on exactly the same fields" do
      entry(role_family_id: @family.role_family_id, level_ordinal: 2)

      error = assert_raises(Operations::Base::ParameterError) { entry(role_family_id: @family.role_family_id, level_ordinal: 2) }
      assert_equal "There is already a band for Engineering, Level 2 in any location", error.message
    end

    should "mark a family's band once the family leaves the framework, keeping its name" do
      entry(role_family_id: @family.role_family_id)
      ActsAsTenant.with_tenant(@tenant) { @family.destroy! }

      listed = call(:PayBands)[:pay_bands].sole
      assert_equal [ "Engineering, Every level", false ], listed.values_at(:level, :in_framework)
    end
  end
end
