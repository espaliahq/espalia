# frozen_string_literal: true

require "test_helper"

class PayBandTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @role = create(:framework_role, tenant: @tenant)
    @level = create(:framework_level, tenant: @tenant, role_id: @role.role_id, code: "E2", title: "Engineer II")
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def band(**attrs)
    PayBand.new(level: @level, currency: "AUD",
                period: "year", minimum: 100, midpoint: 150, maximum: 200, **attrs)
  end

  def site(country, from: Date.current, to: nil, person_id: SecureRandom.uuid_v7)
    OrgFactPeriod.create!(subject_type: "person", subject_id: person_id, fact: "site", value: { country: },
                          effective_from: from, effective_to: to, learned_at: Time.current,
                          event_id: SecureRandom.uuid_v7, learned_by_event_id: SecureRandom.uuid_v7)
  end

  should "name its level by role, code and title, so the name outlives the level" do
    assert_equal [ "Software Engineer", "E2 Engineer II" ], band.values_at(:role_name, :level_name)
    assert_equal "Software Engineer, E2 Engineer II", band.level_label
  end

  should "match a location ignoring case and spaces, and take the Org Graph's spelling" do
    site("New Zealand")
    saved = band(location: "  new   zealand ")
    saved.save!

    assert_equal "New Zealand", saved.location
    assert_equal "new zealand", saved.location_key
  end

  should "read a blank location as any location" do
    saved = band(location: " ")
    saved.save!

    assert saved.any_location?
    assert_equal "Any location", saved.location_name
  end

  should "keep one band per level and location" do
    band(location: "Fixtureland").save!
    duplicate = band(location: "FIXTURELAND")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:base], "There is already a band for this level in FIXTURELAND"
  end

  should "refuse figures out of order, negative or missing" do
    assert_not band(minimum: 300).valid?
    assert_not band(minimum: -1).valid?
    assert_not band(maximum: nil).valid?
  end

  should "keep the currency as an upper-case ISO code and the period as given" do
    assert_equal "AUD", band(currency: " aud ").tap(&:valid?).currency
    assert_not band(currency: "DOLLARS").valid?
    assert_not band(currency: "XYZ").valid?, "three letters, but not an ISO 4217 currency"
    assert band(currency: "nzd").valid?
    assert_not band(period: "week").valid?
  end

  should "give a figure with both decimal places" do
    assert_equal "100.00", band(minimum: 100).figure(:minimum)
    assert_equal "52.50", band(minimum: BigDecimal("52.5")).figure(:minimum)
  end

  should "list the countries the Org Graph holds, one spelling each" do
    site("Fixtureland")
    site("fixtureland")
    site("Testonia")

    assert_equal %w[Fixtureland Testonia], PayBand.known_countries.map(&:capitalize).uniq.sort
    assert_equal 2, PayBand.known_countries.size
  end

  should "offer the country a person is in today, not one they move to later" do
    person_id = SecureRandom.uuid_v7
    site("Fixtureland", from: 1.month.ago.to_date, to: 1.month.from_now.to_date, person_id:)
    site("Testonia", from: 1.month.from_now.to_date, person_id:)

    assert_equal %w[Fixtureland], PayBand.known_countries
  end
end
