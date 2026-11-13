# frozen_string_literal: true

require "test_helper"

class Hris::LevelHandoverTest < ActiveSupport::TestCase
  FakeAdapter = Struct.new(:values, :fields) do
    def provider_name = "hibob"
    def catalogue_id(field_id) = field_id
    def field_catalogue = fields
    def read_field(_field_id, kind:, alongside: nil) = values
  end

  TODAY = Date.new(2026, 11, 13)
  TEAM = Hris::Field.new(id: "work.team", name: "Team", kind: :list,
                         values: [ %w[7 Payments], %w[8 Search], %w[9 Growth] ].map { |id, name| Hris::Field::Value.new(id:, name:) })

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @actor = OrgGraph::Authorization::SYSTEM
    @structure = OrgGraph::StructureCommandHandler.new(actor: @actor)
    @people = OrgGraph::CommandHandler.new(actor: @actor)
    @level_id = SecureRandom.uuid_v7
    @structure.claim_facts(OrgGraph::StructureAggregate::FACTS, "hibob", effective_on: "2026-01-01")
    @structure.define_taxonomy([ { level_id: @level_id, name: "Team" } ], effective_on: "2026-01-01")
    @payments, @search, @legacy = %w[Payments Search Legacy].map do |name|
      SecureRandom.uuid_v7.tap { @structure.create_unit(it, name, level_id: @level_id, effective_on: "2026-01-01") }
    end
    @staff = Array.new(4) { |index| recorded_person("hb-#{index}") }
    @hand_added = recorded_person("hb-hand")
    @joiner = recorded_person("hb-joiner")
    [ [ @staff[0], @payments ], [ @staff[1], @payments ], [ @staff[2], @search ], [ @staff[3], @legacy ],
      [ @hand_added, @payments ] ].each { |person, unit| join(person, unit) }
    @values = { "hb-0" => item("7", "Payments"), "hb-1" => item("8", "Search"), "hb-2" => item("8", "Search"),
                "hb-3" => Hris::FieldValue.blank, "hb-joiner" => item("7", "Payments") }
    @matches = { @payments => "7", @search => "8" }
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  context "#compare" do
    should "suggest a value for each unit by name, and match none" do
      units = compare.units.index_by { it[:name] }

      assert_equal({ key: "7", label: "Payments" }, units["Payments"][:suggestion])
      assert_nil units["Legacy"][:suggestion]
      assert_equal [ "Legacy", "Payments", "Search" ], compare.unresolved.sort
    end

    should "count each unit's members by the value they hold" do
      payments = compare.units.find { it[:name] == "Payments" }

      assert_equal 3, payments[:members]
      assert_equal [ { key: "7", label: "Payments", people: 1 }, { key: "8", label: "Search", people: 1 } ], payments[:held]
    end

    should "list who differs, who is blank, who was added by hand and how many join" do
      comparison = compare(matches: @matches)

      assert_equal [ @staff[1].id ], comparison.differing.map { it[:person_id] }
      assert_equal [ @staff[3].id ], comparison.blank.map { it[:person_id] }
      assert_equal [ @hand_added.id ], comparison.hand_added.map { it[:person_id] }
      assert_equal 1, comparison.joining
      assert_nil comparison.items.find { it[:key] == "9" }[:unit_id]
    end

    should "leave a unit unresolved until it is retired or succeeded into a matched unit" do
      assert_equal [ "Legacy" ], compare(matches: @matches).unresolved
      assert_equal [ "Legacy" ], compare(matches: @matches, resolutions: { @legacy => @legacy }).unresolved
      assert_empty compare(matches: @matches, resolutions: { @legacy => @search }).unresolved
      assert_empty compare(matches: @matches, resolutions: { @legacy => Hris::LevelHandover::RETIRE }).unresolved
    end

    should "count a blank member of a retired unit once against the brake" do
      comparison = compare(matches: @matches, resolutions: { @legacy => Hris::LevelHandover::RETIRE })

      assert_equal [ 1, 1 ], [ comparison.memberships_ended, comparison.units_retired ]
      assert_not comparison.over_brake?
    end

    should "block a unit that can't retire today, so the handover never fails partway" do
      squad_level = SecureRandom.uuid_v7
      @structure.define_taxonomy([ { level_id: @level_id, name: "Team" }, { level_id: squad_level, name: "Squad" } ],
                                 effective_on: "2026-01-01")
      @structure.create_unit(SecureRandom.uuid_v7, "Legacy squad", level_id: squad_level, parent_id: @legacy,
                                                                   effective_on: "2026-01-01")

      comparison = compare(matches: @matches, resolutions: retire_legacy)

      assert_equal [ { unit_id: @legacy, name: "Legacy", reason: "it has live sub-units" } ], comparison.blocked
      error = assert_raises(Hris::LevelHandover::Refused) { hand_over! }
      assert_match(/Legacy \(it has live sub-units\)/, error.message)
      assert_equal "espalia", OrgTaxonomyLevel.find(@level_id).provider
    end

    should "block a unit whose last change falls after today" do
      @structure.rename_unit(@legacy, "Legacy 2027", effective_on: "2027-01-01")

      assert_equal [ "it changes on 2027-01-01" ], compare(matches: @matches, resolutions: retire_legacy).blocked.pluck(:reason)
    end

    should "change its fingerprint when the HRIS changes" do
      before = compare(matches: @matches).fingerprint
      @values["hb-0"] = item("8", "Search")

      assert_not_equal before, compare(matches: @matches).fingerprint
    end

    should "refuse a level the HRIS already supplies" do
      hand_over!
      assert_raises(Hris::LevelHandover::Refused) { compare }
    end
  end

  context "#hand_over!" do
    should "hand the level over as one cause, so memberships agree with the HRIS" do
      hand_over!

      level = OrgTaxonomyLevel.find(@level_id)
      assert_equal [ "hibob", "work.team" ], [ level.provider, level.provider_field ]
      assert_equal "work.team/7", OrgUnit.find(@payments).external_ref
      assert OrgUnit.find(@legacy).retired_on
      assert_equal @search, membership(@staff[1]).unit_id
      assert_nil membership(@staff[3])
      assert_equal [ @payments, "hibob" ], [ membership(@joiner).unit_id, membership(@joiner).provider ]
      assert_equal [ @payments, "espalia" ], [ membership(@hand_added).unit_id, membership(@hand_added).provider ]
      assert_equal "hibob", membership(@staff[0]).provider
      assert_equal 1, written_since(@before).map { it.metadata[:correlation_id] }.uniq.size
    end

    should "leave a member whose item the HRIS dropped as Espalia's, as the mirror reads it" do
      @values["hb-0"] = item("99", "Archived team")

      assert_includes compare(matches: @matches).hand_added.pluck(:person_id), @staff[0].id
      hand_over!
      assert_equal [ @payments, "espalia" ], [ membership(@staff[0]).unit_id, membership(@staff[0]).provider ]
    end

    should "succeed an unmatched unit into the one it names" do
      hand_over!(resolutions: { @legacy => @search })

      assert OrgUnit.find(@legacy).retired_on
      assert_nil membership(@staff[3])
    end

    should "refuse a comparison that has gone stale, writing nothing" do
      fingerprint = compare(matches: @matches, resolutions: retire_legacy).fingerprint
      @values["hb-0"] = item("8", "Search")

      assert_raises(Hris::LevelHandover::Refused) { hand_over!(fingerprint:) }
      assert_equal "espalia", OrgTaxonomyLevel.find(@level_id).provider
    end

    should "refuse while a unit is unresolved" do
      error = assert_raises(Hris::LevelHandover::Refused) { hand_over!(resolutions: {}) }

      assert_match(/Legacy/, error.message)
    end

    context "over the brake" do
      setup do
        @crowd = Array.new(8) { |index| recorded_person("hb-crowd-#{index}").tap { join(it, @legacy) } }
      end

      should "refuse without the counts the comparison showed, naming them" do
        error = assert_raises(Hris::LevelHandover::Refused) { hand_over! }

        assert_match(/ends 9 memberships and retires 1 units/, error.message)
        assert_equal "espalia", OrgTaxonomyLevel.find(@level_id).provider
      end

      should "refuse a count that differs" do
        assert_raises(Hris::LevelHandover::Refused) { hand_over!(confirm: { memberships_ended: 8, units_retired: 1 }) }
      end

      should "hand over once both counts are confirmed" do
        hand_over!(confirm: { memberships_ended: 9, units_retired: 1 })

        assert(@crowd.none? { membership(it) })
        assert_equal "hibob", OrgTaxonomyLevel.find(@level_id).provider
      end
    end
  end

  context "#hand_back!" do
    setup { hand_over! }

    should "keep units and memberships, and leave the retirement standing" do
      handback = handover.compare_handback
      handover.hand_back!(fingerprint: handback.fingerprint, actor: @actor)

      assert_equal [ "espalia", nil ], OrgTaxonomyLevel.find(@level_id).then { [ it.provider, it.provider_field ] }
      assert_nil OrgUnit.find(@payments).external_ref
      assert OrgUnit.find(@legacy).retired_on
      assert_equal [ @payments, "espalia" ], [ membership(@joiner).unit_id, membership(@joiner).provider ]
    end

    should "refuse a stale comparison" do
      fingerprint = handover.compare_handback.fingerprint
      join(recorded_person("hb-late"), @payments, provider: "hibob")

      assert_raises(Hris::LevelHandover::Refused) { handover.hand_back!(fingerprint:, actor: @actor) }
    end
  end

  private

  def handover = Hris::LevelHandover.new(@tenant, OrgTaxonomyLevel.find(@level_id), adapter: FakeAdapter.new(readings, [ TEAM ]), today: TODAY)

  def readings = @values

  def compare(matches: {}, resolutions: {}) = handover.compare(field_id: TEAM.id, matches:, resolutions:)

  def retire_legacy = { @legacy => Hris::LevelHandover::RETIRE }

  def hand_over!(resolutions: retire_legacy, confirm: {}, fingerprint: nil)
    fingerprint ||= compare(matches: @matches, resolutions:).fingerprint
    @before = Rails.configuration.event_store.read.backward.limit(1).first&.event_id
    handover.hand_over!(field_id: TEAM.id, matches: @matches, resolutions:, fingerprint:, confirm:, actor: @actor)
  end

  def written_since(event_id)
    Rails.configuration.event_store.read.from(event_id).to_a
  end

  def item(id, label) = Hris::FieldValue.new(state: :value, id:, label:)

  def recorded_person(external_id)
    person = create(:person, tenant: @tenant, hris_source: "hibob", external_id:)
    @people.record_person(person.id, provider: "hibob", effective_on: "2026-11-01", employment_status: "employed")
    person
  end

  def join(person, unit_id, provider: "espalia")
    @people.set_membership(person.id, unit_id, provider:, effective_on: "2026-11-01")
  end

  def membership(person)
    OrgMembership.in_live_units.find_by(person_id: person.id, unit_id: OrgUnit.where(level_id: @level_id))
  end
end
