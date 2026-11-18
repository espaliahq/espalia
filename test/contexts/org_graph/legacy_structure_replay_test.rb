# frozen_string_literal: true

require "test_helper"

# Replays a structure stream written before kinds stated their own rules (#489):
# levels with none, an added level, a reorder, a removed level, a level an HRIS
# supplies from the start, and one handed over and back. Each kind's rules are
# derived from the order and the providers, as they were then.
class OrgGraph::LegacyStructureReplayTest < ActiveSupport::TestCase
  LEGACY = JSON.parse(Rails.root.join("test/fixtures/files/event_store/legacy_org_structure.json").read)
  FIXTURE_TENANT = "01a1d95d-7b58-71c7-b4a0-9a980c3e2b2b"
  Stored = TeamPlanning::NameSealing::StoredEvent

  DIVISION, DEPARTMENT, TEAM, SQUAD = (1..4).map { "01a1d95d-0001-7000-8000-00000000000#{it}" }
  OPS, SALES, ENGINEERING, PAYMENTS, PLATFORM, LENDING, CHECKOUT = (1..7).map { "01a1d95d-0002-7000-8000-00000000000#{it}" }

  setup do
    @tenant = create(:tenant)
    user = create(:user)
    @context = AuthorizationContext.new(user:, tenant_user: create(:tenant_user, user:, tenant: @tenant), person: nil)
    stream = as_tenant { EventStreamNaming.org_structure_stream }
    LEGACY.each.with_index do |event, position|
      Stored.create!(event.slice("event_id", "event_type", "data", "created_at", "valid_at")
                          .merge("metadata" => event["metadata"].sub(FIXTURE_TENANT, @tenant.id)))
      Stored.connection.exec_insert(
        "INSERT INTO event_store_events_in_streams (stream, position, event_id, created_at) VALUES ($1, $2, $3, $4)", "Stream",
        [ stream, position, event["event_id"], event["created_at"] ]
      )
    end
    [ OrgGraph::Projections::Structure, OrgGraph::Projections::History ].each do |projection|
      as_tenant { projection.reset!(tenant: @tenant) }
      Projections::Replayer.replay(projection_class: projection, tenant: @tenant)
    end
  end

  TREE = {
    "Ops" => [ nil, DIVISION, "hibob" ], "Sales" => [ nil, DIVISION, "hibob" ], "Engineering" => [ OPS, DEPARTMENT, "hibob" ],
    "Payments" => [ ENGINEERING, TEAM, "espalia" ], "Platform" => [ OPS, TEAM, "espalia" ], "Lending" => [ nil, TEAM, "espalia" ],
    "Checkout" => [ PAYMENTS, SQUAD, "espalia" ]
  }.freeze
  # Each kind may sit beneath any kind above it, or at the top.
  RULES = {
    "Division" => [ [], true ], "Department" => [ [ DIVISION ], true ], "Team" => [ [ DIVISION, DEPARTMENT ], true ],
    "Squad" => [ [ DIVISION, DEPARTMENT, TEAM ], true ]
  }.freeze

  should "rebuild each unit's parent, kind and provider" do
    assert_equal TREE, as_tenant { OrgUnit.all.to_h { [ it.name, [ it.parent_id, it.level_id, it.provider ] ] } }
  end

  should "keep the kinds in their last order, with no rules of their own, in the top structure" do
    rows = as_tenant { OrgTaxonomyLevel.order(:position).pluck(:id, :name, :provider, :parent_level_ids, :top, :structure_unit_id) }

    assert_equal [ [ DIVISION, "Division", "hibob" ], [ DEPARTMENT, "Department", "hibob" ], [ TEAM, "Team", "espalia" ],
                   [ SQUAD, "Squad", "espalia" ] ], rows.map { it.first(3) }
    assert rows.all? { it.last(3).none? }
  end

  should "derive each kind's rules from the order, alike in the read model and the aggregate" do
    as_tenant do
      assert_equal RULES, rules(OrgTaxonomyLevel.taxonomy.kinds)
      structure = OrgGraph::Repository.new.load_structure
      assert_equal RULES, rules(structure.taxonomy.kinds)
      assert_empty structure.misplaced_units
      assert_empty structure.declared_structures
    end
  end

  should "pass the taxonomy check" do
    assert_equal [ 1, [], [] ], as_tenant { OrgGraph::TaxonomyCheck.new.then { [ it.structures, it.misplaced, it.out_of_order ] } }
  end

  should "read the same tree and rules for today from the history" do
    snapshot = as_of("2026-06-01")

    assert_equal TREE.transform_values { it.first(2) }, snapshot.units.to_h { [ it.name, [ it.parent_id, it.level_id ] ] }
    assert_equal RULES, rules(snapshot.kinds)
    assert_empty snapshot.structures
  end

  should "read the kinds in the order of each day, with a level added and later removed" do
    assert_equal %w[Division Department Guild Team Squad], as_of("2026-02-20").kinds.map(&:name)
    assert_equal %w[Division Department Team Squad], as_of("2026-03-05").kinds.map(&:name)
  end

  # On purpose: the HRIS mirror only ever read a unit's parent from the level
  # directly above, so an HRIS kind is held to that. `org_graph:taxonomy:check`
  # reports any unit the narrowing leaves misplaced; Platform, beneath Ops,
  # would have been one while an HRIS supplied the teams.
  should "narrow a kind to the HRIS level directly above while an HRIS supplies it, and widen it once handed back" do
    april = as_of("2026-04-20").kinds.index_by(&:name)

    assert_equal [ "hibob", [ DEPARTMENT ] ], [ april["Team"].provider, april["Team"].parent_ids ]
    assert_equal [ "espalia", [ DIVISION, DEPARTMENT ] ], as_of("2026-06-01").kinds.find { it.name == "Team" }.then { [ it.provider, it.parent_ids ] }
  end

  private

  def as_of(date) = as_tenant { OrgGraph::AsOf.new(context: @context, date: Date.iso8601(date)).call }

  def rules(kinds) = kinds.to_h { [ it.name, [ it.parent_ids, it.top ] ] }

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)
end
