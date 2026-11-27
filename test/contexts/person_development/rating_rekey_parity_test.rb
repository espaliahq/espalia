# frozen_string_literal: true

require "test_helper"

# The aggregate's rating maps must re-key on FrameworkVersionMigrated exactly
# as CurrentAssessment re-keys its rows (#538): the same stream, fed to both,
# leaves the same cells holding the same values after every event.
class PersonDevelopment::RatingRekeyParityTest < ActiveSupport::TestCase
  E = PersonDevelopment::Events

  setup do
    @tenant = create(:tenant)
    @projection = PersonDevelopment::Projections::CurrentAssessment.new
    @person_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
    @role_id = SecureRandom.uuid_v7
    @cycle_id = SecureRandom.uuid_v7
    @next_cycle_id = SecureRandom.uuid_v7
    # Capabilities are named in the tests and stored under uuids.
    @ids = Hash.new { |ids, name| ids[name] = SecureRandom.uuid_v7 }
    ActsAsTenant.with_tenant(@tenant) do
      create(:assessment_cycle, :closed, tenant: @tenant, cycle_id: @cycle_id, framework_id: @framework_id)
      create(:assessment_cycle, tenant: @tenant, cycle_id: @next_cycle_id, framework_id: @framework_id)
    end
  end

  %w[same evolved archived split new].each do |mapping_type|
    should "agree on a #{mapping_type} mapping" do
      to = mapping_type.in?(%w[evolved]) ? "survivor" : nil
      assert_parity(*start, self_rated("retiring", 3), manager_rated("retiring", 3), aligned("retiring", 3),
        self_rated("retiring", 2), migrated(mapping("retiring", to, mapping_type)))
    end
  end

  should "agree on a capability mapped onto itself" do
    assert_parity(*start, self_rated("retiring", 3), migrated(mapping("retiring", "retiring", "same")))
  end

  should "keep the retiring cell where the survivor is rated on the other side only" do
    assert_parity(*start, self_rated("retiring", 3, "some"), manager_rated("survivor", 3, "consistent"),
      self_rated("retiring", 2), migrated(mapping("retiring", "survivor")))

    assert_equal "some", maps[:self][[ "retiring", 3 ]]
    assert_equal "consistent", maps[:manager][[ "survivor", 3 ]]
    assert_equal "occasional", maps[:self][[ "survivor", 2 ]]
  end

  should "keep the retiring cell where the survivor's cell was rated and cleared" do
    assert_parity(*start, self_rated("survivor", 3), event(E::SelfRatingCleared, capability_stable_id: @ids["survivor"], level_ordinal: 3, cycle_id: @cycle_id),
      manager_rated("retiring", 3), migrated(mapping("retiring", "survivor")))

    assert_equal({ [ "retiring", 3 ] => "occasional" }, maps[:manager])
  end

  should "apply two mappings in payload order when one's target is the other's source" do
    assert_parity(*start, self_rated("first", 3), self_rated("first", 2), self_rated("second", 3),
      migrated(mapping("first", "second"), mapping("second", "third")))

    assert_equal [ [ "first", 3 ], [ "third", 2 ], [ "third", 3 ] ], maps[:self].keys.sort
  end

  should "agree when a cycle is joined after the publish" do
    assert_parity(*start, self_rated("retiring", 3), migrated(mapping("retiring", "survivor")),
      event(E::LeftAssessmentCycle, cycle_id: @cycle_id), joined(@next_cycle_id))
    assert_parity(self_rated("survivor", 3), manager_rated("retiring", 2), migrated(mapping("retiring", "survivor"), version: 3))
  end

  should "agree after a cycle concludes, whose rows a later publish still re-keys" do
    assert_parity(*start, self_rated("retiring", 3), event(E::AssessmentCycleConcluded, cycle_id: @cycle_id),
      migrated(mapping("retiring", "survivor")))
  end

  should "leave a completed home alignment's cells where they are, and follow again once it reopens" do
    assert_parity(*start, self_rated("retiring", 3), aligned_start, aligned("retiring", 3),
      event(E::FullAlignmentCompleted, cycle_id: @cycle_id, completed_by_id: "manager"),
      migrated(mapping("retiring", "survivor")))
    assert_equal [ [ "retiring", 3 ] ], maps[:aligned].keys

    assert_parity(event(E::AlignmentReopened, cycle_id: @cycle_id, reopened_by_id: "manager"),
      migrated(mapping("retiring", "survivor"), version: 3))
    assert_equal [ [ "survivor", 3 ] ], maps[:aligned].keys
  end

  should "follow a lens role's completed alignment, which leaves the home cycle open" do
    lens = SecureRandom.uuid_v7
    assert_parity(*start, self_rated("retiring", 3),
      event(E::AlignmentStarted, cycle_id: @cycle_id, started_by_id: "manager", role_id: lens, level_ordinal: 3, cell_keys: [ [ @ids["retiring"], 3 ] ]),
      aligned("retiring", 3, role_id: lens),
      event(E::FullAlignmentCompleted, cycle_id: @cycle_id, completed_by_id: "manager", role_id: lens),
      migrated(mapping("retiring", "survivor")))
  end

  # History written before the aggregate followed: the old aggregate kept
  # "retiring", so later events name either id.
  should "agree on a stream agreed by hand on the survivor after a pre-fix publish" do
    assert_parity(*start, self_rated("retiring", 3), manager_rated("retiring", 3),
      migrated(mapping("retiring", "survivor")),
      event(E::AlignmentStarted, cycle_id: @cycle_id, started_by_id: "manager", role_id: @role_id, level_ordinal: 3, cell_keys: [ [ @ids["survivor"], 3 ] ]),
      aligned("survivor", 3, role_id: @role_id))
  end

  should "agree on a stream whose whole-assessment start auto-aligned the retired key" do
    assert_parity(*start, self_rated("retiring", 3), manager_rated("retiring", 3),
      migrated(mapping("retiring", "survivor")), aligned_start, aligned("retiring", 3))

    assert_equal({ [ "survivor", 3 ] => "occasional" }, maps[:self])
    assert_equal({ [ "retiring", 3 ] => "occasional" }, maps[:aligned])
  end

  should "load a stream whose mappings name capabilities the aggregate never saw" do
    assert_parity(*start, self_rated("retiring", 3),
      migrated(mapping("unknown", "survivor"), mapping("unknown", nil, "archived"), mapping(nil, nil, "new"),
        { from_stable_id: @ids["retiring"], mapping_type: "evolved" }, { mapping_type: "renamed" }))
    assert_equal({ [ "retiring", 3 ] => "occasional" }, maps[:self])

    append(E::FrameworkVersionMigrated, project: false, framework_id: @framework_id, old_version: 2, new_version: 3, mappings: nil)
    assert_nothing_raised { load_aggregate }
  end

  private

  def start
    [ event(E::PersonAssignedToFramework, person_id: @person_id, framework_id: @framework_id, role_id: @role_id, level_id: SecureRandom.uuid_v7),
      joined(@cycle_id) ]
  end

  def joined(cycle_id) = event(E::JoinedAssessmentCycle, cycle_id: cycle_id, framework_version: 1)

  def self_rated(cap, ordinal, frequency = "occasional")
    event(E::SelfRated, capability_stable_id: @ids[cap], level_ordinal: ordinal, frequency: frequency, cycle_id: current_cycle, source: "human")
  end

  def manager_rated(cap, ordinal, frequency = "occasional")
    event(E::ManagerRated, capability_stable_id: @ids[cap], level_ordinal: ordinal, frequency: frequency, cycle_id: current_cycle,
      source: "human", rated_by_id: "manager")
  end

  def aligned(cap, ordinal, role_id: nil)
    event(E::AssessmentAligned, capability_stable_id: @ids[cap], level_ordinal: ordinal, aligned_frequency: "occasional",
      cycle_id: current_cycle, aligned_by_id: "manager", role_id: role_id)
  end

  def aligned_start = event(E::AlignmentStarted, cycle_id: @cycle_id, started_by_id: "manager")

  def mapping(from, to, type = "evolved")
    { from_stable_id: from && @ids[from], to_stable_id: to && @ids[to], mapping_type: type, requires_reassessment: false }
  end

  def migrated(*mappings, version: 2)
    event(E::FrameworkVersionMigrated, framework_id: @framework_id, old_version: version - 1, new_version: version, mappings: mappings)
  end

  def event(klass, **data) = [ klass, data ]

  def current_cycle = @current_cycle || @cycle_id

  # Appends each event, projects it, reloads the aggregate and compares.
  def assert_parity(*events)
    events.each do |klass, data|
      @current_cycle = data[:cycle_id] if klass == E::JoinedAssessmentCycle
      append(klass, **data)
      assert_equal rows, maps, "after #{klass.name.demodulize} #{data.inspect}"
    end
  end

  def append(klass, project: true, **data)
    event = klass.new(data: data, metadata: { tenant_id: @tenant.id, person_id: @person_id, framework_id: @framework_id })
    ActsAsTenant.with_tenant(@tenant) do
      Rails.configuration.event_store.append(event, stream_name: EventStreamNaming.person_development_stream(@person_id, @framework_id))
      @projection.call(event) if project
    end
  end

  def load_aggregate
    ActsAsTenant.with_tenant(@tenant) { PersonDevelopment::Repository.new.load(@person_id, @framework_id) }
  end

  def maps
    aggregate = load_aggregate
    named({
      cells: aggregate.instance_variable_get(:@rated_cells).to_a,
      self: aggregate.instance_variable_get(:@self_ratings),
      manager: aggregate.instance_variable_get(:@manager_ratings),
      aligned: aggregate.instance_variable_get(:@aligned_ratings)
    })
  end

  def named(state)
    names = @ids.invert
    rename = ->((cap, ordinal)) { [ names.fetch(cap, cap), ordinal ] }
    state.to_h do |part, cells|
      [ part, cells.is_a?(Hash) ? cells.transform_keys(&rename) : cells.map(&rename).sort ]
    end
  end

  def rows
    scope = ActsAsTenant.with_tenant(@tenant) do
      AssessmentLevelRating.across_all_roles.where(person_id: @person_id, cycle_id: current_cycle).to_a
    end
    by_cell = scope.index_by { |row| [ row.capability_stable_id, row.level_ordinal ] }
    side = ->(column) { by_cell.filter_map { |cell, row| [ cell, row[column] ] if row[column] }.to_h }
    named({
      cells: by_cell.keys,
      self: side.(:self_rated_frequency),
      manager: side.(:manager_rated_frequency),
      aligned: side.(:aligned_frequency)
    })
  end
end
