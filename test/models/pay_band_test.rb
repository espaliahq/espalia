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

  def lookup = PayBand::Lookup.new(PayBand.order(:position).to_a, tenant_id: @tenant.id)

  def entry(role: nil, role_family: nil, level_ordinal: nil, location: nil, midpoint: 150)
    PayBand.new(location:, currency: "AUD", period: "year", minimum: 0, midpoint:, maximum: 1_000)
           .tap { it.match_on(role:, role_family:, level_ordinal:) }.tap(&:save!)
  end

  def site(country, from: Date.current, to: nil, person_id: SecureRandom.uuid_v7)
    OrgFactPeriod.create!(subject_type: "person", subject_id: person_id, fact: "site", value: { country: },
                          effective_from: from, effective_to: to, learned_at: Time.current,
                          event_id: SecureRandom.uuid_v7, learned_by_event_id: SecureRandom.uuid_v7)
  end

  should "make a full-time year of any period, exactly, an hour by the hours given" do
    assert_equal [ 150r, 1_800r, 300_000r ], %w[year month hour].map { band(period: it).yearly(:midpoint, hours_per_year: 2_000r) }
    assert_equal Rational(2_001, 10) * 1_950, band(period: "hour", midpoint: "200.1").yearly(:midpoint, hours_per_year: 1_950r)
  end

  should "price a seat at its country's band, ignoring case and spacing, else at the band for any location" do
    [ band(location: "Atlantis"), band(location: nil), band(location: "Lemuria") ].each(&:save!)

    assert_equal [ "Atlantis", "Lemuria", "Any location", "Any location" ], [ " atlantis ", "LEMURIA", "Mu", nil ].map { lookup.covering(@level.level_id, it).location_name }
    PayBand.where(location_key: "").destroy_all
    assert_nil lookup.covering(@level.level_id, "Mu")
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

  should "keep one band per matcher" do
    band(location: "Fixtureland").save!
    duplicate = band(location: "FIXTURELAND")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:base], "There is already a band for Software Engineer, E2 Engineer II in FIXTURELAND"
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

  context "as an ordered list" do
    setup do
      @level.update!(ordinal: 2)
      @family = create(:framework_role_family, tenant: @tenant, role_family_id: @role.role_family_id, name: "Engineering")
      @other_role = create(:framework_role, tenant: @tenant, name: "Designer")
    end

    should "let the last band that matches have the last word, skipping one that doesn't match" do
      general = entry(level_ordinal: 2, midpoint: 100)
      entry(role: @other_role, level_ordinal: 2, midpoint: 200)
      assert_equal [ general, 0 ], lookup.deciding(@level.level_id, "Fixtureland")

      specific = entry(role: @role, level_ordinal: 2, midpoint: 300)
      assert_equal [ specific, 2 ], lookup.deciding(@level.level_id, "Fixtureland")
      assert_equal [ 1, 2, 3 ], PayBand.order(:position).map(&:position)
    end

    should "change the winner when the order changes" do
      family = entry(role_family: @family, level_ordinal: 2, location: "Fixtureland")
      role = band.tap(&:save!)
      assert_equal role, lookup.covering(@level.level_id, "Fixtureland")

      assert PayBand.reorder!([ role.id, family.id ])
      assert_equal family, lookup.covering(@level.level_id, "Fixtureland")
      assert_equal role, lookup.covering(@level.level_id, "Testonia")
      assert_not PayBand.reorder!([ role.id ])
    end

    should "land a new band after the last band no more specific than it, and close the gap a removed one leaves" do
      role_x = band(location: "Fixtureland").tap(&:save!)
      role = band.tap(&:save!)
      family = entry(role_family: @family, level_ordinal: 2)
      everything = entry(level_ordinal: 2)
      anything_x = entry(location: "Fixtureland")

      assert_equal [ everything, anything_x, family, role, role_x ], PayBand.order(:position).to_a
      family.destroy!
      assert_equal [ 1, 2, 3, 4 ], PayBand.order(:position).pluck(:position)
    end

    should "flag a band a later band matches every seat of" do
      family = entry(role_family: @family, level_ordinal: 2)
      role = band.tap(&:save!)
      everything = entry(level_ordinal: 2)
      PayBand.reorder!([ family.id, role.id, everything.id ])

      assert_equal [ family, role ], lookup.shadowed
      PayBand.reorder!([ everything.id, family.id, role.id ])
      assert_empty lookup.shadowed
    end

    should "match on a role or a family, never both" do
      both = PayBand.new(role_id: @role.role_id, role_family_id: @family.role_family_id, role_name: "x", level_name: "y",
                         currency: "AUD", period: "year", minimum: 0, midpoint: 1, maximum: 2)

      assert_not both.valid?
      assert_equal [ "Engineering", "Level 3" ], entry(role_family: @family, level_ordinal: 3).values_at(:role_name, :level_name)
      assert_equal [ "Every role", "Every level" ], entry(location: "Testonia").values_at(:role_name, :level_name)
      assert_equal({ role_id: @role.role_id, level_ordinal: 2 }, entry(role: @role, level_ordinal: 2, location: "Mu").matcher_fields.except(:location))
    end

    should "still price a seat at a level that has left the framework from the band made from it" do
      role = band.tap(&:save!)
      entry(role_family: @family, level_ordinal: 2, location: "Fixtureland")
      left = @level.level_id
      @level.destroy!

      assert_equal role, lookup.covering(left, "Fixtureland")
    end
  end
end
