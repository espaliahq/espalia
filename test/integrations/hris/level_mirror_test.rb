# frozen_string_literal: true

require "test_helper"

class Hris::LevelMirrorTest < ActiveSupport::TestCase
  Reading = Struct.new(:values) do
    def field_value(field_id, kind:) = values.fetch(field_id, Hris::FieldValue.withheld)
  end

  TODAY = Date.new(2026, 11, 13)

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @division = SecureRandom.uuid_v7
    @team = SecureRandom.uuid_v7
    @structure.claim_facts(OrgGraph::StructureAggregate::FACTS, "hibob", effective_on: "2026-01-01")
    @structure.define_taxonomy([ { level_id: @division, name: "Division" }, { level_id: @team, name: "Team" } ],
                               effective_on: "2026-01-01")
    @structure.set_level_provider(@division, "hibob", field: "work.division", effective_on: "2026-01-01")
    @structure.set_level_provider(@team, "hibob", field: "work.department", effective_on: "2026-01-01")
    @catalogue = [ division_field(%w[d1 Product], %w[d2 Platform]), team_field(%w[t1 Payments], %w[t2 Search]) ]
    @staff = Array.new(3) { |index| recorded_person("hb-#{index}") }
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  context "units" do
    should "create a unit for each value someone holds, under the parent its people share" do
      mirror(@staff[0] => { division: "d1", team: "t1" }, @staff[1] => { division: "d1", team: "t1" })

      payments = unit("work.department/t1")
      assert_equal "Payments", payments.name
      assert_equal unit("work.division/d1").id, payments.parent_id
      assert_nil OrgUnit.find_by(external_ref: "work.department/t2")
    end

    should "rename a unit when its list item is renamed" do
      mirror(@staff[0] => { division: "d1", team: "t1" })
      @catalogue[1] = team_field(%w[t1 Payouts])
      mirror(@staff[0] => { division: "d1", team: "t1" })

      assert_equal "Payouts", unit("work.department/t1").name
    end

    should "rename a unit nobody holds when its list item is renamed" do
      mirror(@staff[0] => { division: "d1", team: "t1" })
      mirror(@staff[0] => { division: "d1", team: "t2" })
      @catalogue[1] = team_field(%w[t1 Payouts], %w[t2 Search])
      mirror(@staff[0] => { division: "d1", team: "t2" })

      assert_equal "Payouts", unit("work.department/t1").name
    end

    should "retire a unit whose list item is archived, ending what it held" do
      mirror(@staff[0] => { division: "d1", team: "t1" })
      @catalogue[1] = team_field(%w[t2 Search])
      mirror(@staff[0] => { division: "d1", team: "t1" })

      assert_not OrgUnit.live.exists?(external_ref: "work.department/t1")
      assert_not OrgMembership.in_live_units.exists?(person_id: @staff[0].id, unit_id: OrgUnit.where(level_id: @team))
    end

    should "keep a text unit nobody is seen holding while a record can't be read" do
      @catalogue = [ division_field(%w[d1 Product]), Hris::Field.new(id: "work.department", name: "Team", kind: :text) ]
      mirror(@staff[0] => { division: "d1", team_label: "Payments" })
      mirror(@staff[0] => { division: "d1", team: :unreadable })

      assert OrgUnit.live.exists?(external_ref: "work.department/Payments")
    end

    should "keep a text unit nobody is seen holding while a record withholds the field" do
      @catalogue = [ division_field(%w[d1 Product]), Hris::Field.new(id: "work.department", name: "Team", kind: :text) ]
      mirror(@staff[0] => { division: "d1", team_label: "Payments" })
      mirror(@staff[0] => { division: "d1" })

      assert OrgUnit.live.exists?(external_ref: "work.department/Payments")
    end
  end

  context "memberships" do
    setup do
      mirror(@staff[0] => { division: "d1", team: "t1" }, @staff[1] => { division: "d1", team: "t1" })
    end

    should "move a person whose value changes, end one sent blank, and keep one withheld" do
      result = mirror(@staff[0] => { division: "d1", team: "t2" }, @staff[1] => { division: "d1", team: :blank })

      assert_equal unit("work.department/t2").id, team_membership(@staff[0])&.unit_id
      assert_nil team_membership(@staff[1])
      assert_empty result[:errors]

      mirror(@staff[0] => { division: "d1" })
      assert_equal unit("work.department/t2").id, team_membership(@staff[0])&.unit_id
    end

    should "change nothing for a person whose value can't be read" do
      result = mirror(@staff[0] => { division: "d1", team: :unreadable }, @staff[1] => { division: "d1", team: :unreadable })

      assert_equal unit("work.department/t1").id, team_membership(@staff[0])&.unit_id
      assert_equal unit("work.department/t1").id, team_membership(@staff[1])&.unit_id
      assert_empty result[:errors]
    end

    should "leave a hand-added person's Espalia membership alone" do
      hand_added = create(:person, tenant: @tenant)
      @people.record_person(hand_added.id, provider: "espalia", effective_on: "2026-11-01", employment_status: "employed")
      @people.set_membership(hand_added.id, unit("work.department/t1").id, provider: "espalia", effective_on: "2026-11-01")

      mirror(@staff[0] => { division: "d1", team: "t1" })

      assert_equal "espalia", OrgMembership.find_by!(person_id: hand_added.id).provider
    end

    should "not give a second membership to someone Espalia placed, once the HRIS starts sending them" do
      hand_added = create(:person, tenant: @tenant)
      @people.record_person(hand_added.id, provider: "espalia", effective_on: "2026-11-01", employment_status: "employed")
      @people.set_membership(hand_added.id, unit("work.department/t1").id, provider: "espalia", effective_on: "2026-11-01")
      hand_added.update!(hris_source: "hibob", external_id: "hb-late")

      mirror(hand_added => { division: "d1", team: "t2" })

      assert_equal [ "espalia" ], OrgMembership.where(person_id: hand_added.id, unit_id: OrgUnit.where(level_id: @team)).pluck(:provider)
    end

    should "write each person's change as its own cause, by SYSTEM, from the HRIS, dated today" do
      mirror(@staff[0] => { division: "d1", team: "t2" }, @staff[1] => { division: "d1", team: "t2" })

      events = [ @staff[0], @staff[1] ].map { |person| person_events(person).last }
      assert_equal [ OrgGraph::Events::MembershipMoved ] * 2, events.map(&:class)
      assert_equal 2, events.map { it.metadata[:correlation_id] }.uniq.size
      assert(events.all? { it.data[:effective_on] == TODAY.iso8601 })
    end
  end

  context "parents" do
    should "list a unit whose people sit under different units above, and keep its parent" do
      mirror(@staff[0] => { division: "d1", team: "t1" })
      result = mirror(@staff[0] => { division: "d1", team: "t1" }, @staff[1] => { division: "d2", team: "t1" })

      assert_equal [ "Payments" ], result[:split_units].map { it[:name] }
      assert_equal unit("work.division/d1").id, unit("work.department/t1").parent_id
    end

    should "list a new unit whose people disagree, and create it with no parent" do
      result = mirror(@staff[0] => { division: "d1", team: "t1" }, @staff[1] => { division: "d2", team: "t1" })

      assert_equal [ "Payments" ], result[:split_units].map { it[:name] }
      assert_nil unit("work.department/t1").parent_id
    end

    should "start over when a sync between two readings reads no parent" do
      mirror(@staff[0] => { division: "d1", team: "t1" })
      mirror(@staff[0] => { division: "d2", team: "t1" })
      mirror(@staff[0] => { team: "t1" })
      mirror(@staff[0] => { division: "d2", team: "t1" })

      assert_equal unit("work.division/d1").id, unit("work.department/t1").parent_id
    end

    should "start over when a sync between two readings reads nobody in the unit" do
      mirror(@staff[0] => { division: "d1", team: "t1" })
      mirror(@staff[0] => { division: "d2", team: "t1" })
      mirror(@staff[0] => { division: "d2" })
      mirror(@staff[0] => { division: "d2", team: "t1" })

      assert_equal unit("work.division/d1").id, unit("work.department/t1").parent_id
    end

    should "start over when a sync between two readings skips the unit's level" do
      mirror(@staff[0] => { division: "d1", team: "t1" })
      mirror(@staff[0] => { division: "d2", team: "t1" })
      catalogue = @catalogue
      @catalogue = [ catalogue[0] ]
      mirror(@staff[0] => { division: "d2", team: "t1" })
      @catalogue = catalogue
      mirror(@staff[0] => { division: "d2", team: "t1" })

      assert_equal unit("work.division/d1").id, unit("work.department/t1").parent_id
    end

    should "move a unit only once two syncs in a row read the same new parent" do
      mirror(@staff[0] => { division: "d1", team: "t1" })
      platform = { division: "d2", team: "t1" }

      mirror(@staff[0] => platform)
      assert_equal unit("work.division/d1").id, unit("work.department/t1").parent_id

      mirror(@staff[0] => platform)
      assert_equal unit("work.division/d2").id, unit("work.department/t1").parent_id
      assert_not HrisUnitParentProposal.exists?
    end

    should "keep the parent of a unit nobody reads a value for" do
      mirror(@staff[0] => { division: "d1", team: "t1" })
      mirror(@staff[0] => { team: "t1" })
      mirror(@staff[0] => { team: "t1" })

      assert_equal unit("work.division/d1").id, unit("work.department/t1").parent_id
    end
  end

  context "brakes" do
    should "end no membership when more would end than the brake allows" do
      crowd = Array.new(8) { |index| recorded_person("hb-crowd-#{index}") }
      mirror(crowd.to_h { [ it, { division: "d1", team: "t1" } ] })

      result = mirror(crowd.to_h { [ it, { division: "d1", team: :blank } ] })

      assert(crowd.all? { team_membership(it) })
      assert_match(/memberships would end/, result[:errors].sole[:error])
    end

    should "retire no unit when more would retire than the brake allows" do
      @catalogue[1] = team_field(*Array.new(8) { |index| [ "t#{index}", "Team #{index}" ] })
      mirror(Array.new(8) { |index| [ recorded_person("hb-team-#{index}"), { division: "d1", team: "t#{index}" } ] }.to_h)
      @catalogue[1] = team_field(%w[t99 Other])
      result = mirror({})

      assert_equal 8, OrgUnit.live.where(level_id: @team).count
      assert_match(/mirrored units would retire/, result[:errors].sole[:error])
    end
  end

  should "skip a list level whose items the HRIS didn't send, retiring nothing" do
    mirror(@staff[0] => { division: "d1", team: "t1" })
    @catalogue[1] = team_field
    result = mirror(@staff[0] => { division: "d1", team: "t1" })

    assert OrgUnit.live.exists?(external_ref: "work.department/t1")
    assert_match(/sent no items for Department/, result[:errors].sole[:error])
  end

  should "skip a level whose field the HRIS no longer has, and say so" do
    @catalogue = [ division_field(%w[d1 Product]) ]
    result = mirror(@staff[0] => { division: "d1", team: "t1" })

    assert OrgUnit.exists?(external_ref: "work.division/d1")
    assert_not OrgUnit.exists?(level_id: @team)
    assert_match(/no field work.department/, result[:errors].sole[:error])
  end

  private

  def mirror(readings)
    result = { errors: [], split_units: [], org_graph_events: 0 }
    Hris::LevelMirror.new(provider: "hibob", catalogue: @catalogue, readings: readings.to_h { |person, held| [ person, reading(held) ] },
                          result:, today: TODAY).call
    result
  end

  def reading(held)
    values = {}
    values["work.division"] = Hris::FieldValue.new(state: :value, id: held[:division], label: held[:division]) if held[:division]
    case held[:team]
    when :blank then values["work.department"] = Hris::FieldValue.blank
    when :unreadable then values["work.department"] = Hris::FieldValue.unreadable
    when String then values["work.department"] = Hris::FieldValue.new(state: :value, id: held[:team], label: held[:team])
    end
    values["work.department"] = Hris::FieldValue.new(state: :value, label: held[:team_label]) if held[:team_label]
    Reading.new(values)
  end

  def division_field(*items) = list_field("work.division", "Division", items)

  def team_field(*items) = list_field("work.department", "Department", items)

  def list_field(id, name, items)
    Hris::Field.new(id:, name:, kind: :list, values: items.map { |item_id, label| Hris::Field::Value.new(id: item_id, name: label) })
  end

  def recorded_person(external_id)
    person = create(:person, tenant: @tenant, hris_source: "hibob", external_id:)
    @people.record_person(person.id, provider: "hibob", effective_on: "2026-11-01", employment_status: "employed")
    person
  end

  def unit(ref) = OrgUnit.live.find_by!(external_ref: ref)

  def team_membership(person)
    OrgMembership.in_live_units.find_by(person_id: person.id, unit_id: OrgUnit.where(level_id: @team))
  end

  def person_events(person)
    Rails.configuration.event_store.read.stream(EventStreamNaming.person_stream(person.id)).to_a
  end
end
