# frozen_string_literal: true

require "test_helper"

class OrgGraph::StructureCommandHandlerTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @handler = OrgGraph::StructureCommandHandler.new
    @department = SecureRandom.uuid_v7
    @team = SecureRandom.uuid_v7
    @squad = SecureRandom.uuid_v7
    @actor = SecureRandom.uuid_v7
    @today = Date.new(2026, 11, 1)

    as_tenant do
      @handler.define_taxonomy(levels(%w[Department Team Squad]), effective_on: @today, defined_by_id: @actor)
    end
  end

  context "the stream" do
    should "hold the tenant's taxonomy and units, with the tenant in each event's metadata" do
      create_unit(@team, "Payments", level: "Team")
      events = structure_events

      assert_equal [ OrgGraph::Events::TaxonomyDefined, OrgGraph::Events::UnitCreated ], events.map(&:class)
      assert(events.all? { |event| event.metadata[:tenant_id] == @tenant.id })
    end
  end

  context "#define_taxonomy" do
    should "record the levels top first, with the date they took effect" do
      data = structure_events.first.data

      assert_equal %w[Department Team Squad], data[:levels].map { |level| level[:name] }
      assert_equal "2026-11-01", data[:effective_on]
      assert_equal @actor, data[:defined_by_id]
    end

    should "record a redefinition like any other change, with what it replaced" do
      as_tenant do
        @handler.define_taxonomy(levels(%w[Department Tribe Squad]), effective_on: @today + 1)
      end

      redefined = structure_events.last
      assert_kind_of OrgGraph::Events::TaxonomyDefined, redefined
      assert_equal %w[Department Tribe Squad], redefined.data[:levels].map { |level| level[:name] }
      assert_equal %w[Department Team Squad], redefined.data[:previous_levels].map { |level| level[:name] }
    end

    should "write nothing when the taxonomy is unchanged" do
      assert_no_difference -> { structure_events.size } do
        as_tenant { @handler.define_taxonomy(levels(%w[Department Team Squad]), effective_on: @today) }
      end
    end

    should "refuse to drop a level that holds a live unit" do
      create_unit(@squad, "Checkout", level: "Squad")

      error = assert_raises(RuntimeError) do
        as_tenant { @handler.define_taxonomy(levels(%w[Department Team]), effective_on: @today) }
      end
      assert_match "holds units", error.message
    end

    should "refuse to drop a level a retired unit held" do
      create_unit(@squad, "Checkout", level: "Squad")
      as_tenant { @handler.retire_unit(@squad, effective_on: @today) }

      assert_raises(RuntimeError) do
        as_tenant { @handler.define_taxonomy(levels(%w[Department Team]), effective_on: @today) }
      end
    end

    should "refuse a level id that isn't a UUID" do
      assert_raises(ArgumentError) do
        as_tenant { @handler.define_taxonomy([ { level_id: "dept", name: "Department" } ], effective_on: @today) }
      end
    end

    should "refuse to reorder the levels in use" do
      create_unit(@department, "Engineering", level: "Department")
      create_unit(@team, "Payments", level: "Team", parent_id: @department)

      assert_raises(RuntimeError) do
        as_tenant { @handler.define_taxonomy(levels(%w[Team Department Squad]), effective_on: @today) }
      end
    end

    should "refuse duplicate or blank level names" do
      assert_raises(ArgumentError) do
        as_tenant { @handler.define_taxonomy(levels([ "Team", "team" ]), effective_on: @today) }
      end
      assert_raises(ArgumentError) do
        as_tenant { @handler.define_taxonomy(levels([ " " ]), effective_on: @today) }
      end
    end
  end

  context "#create_unit" do
    should "give the unit a stable id, a level, a provider and an effective date" do
      create_unit(@team, "  Payments ", level: "Team")
      data = structure_events.last.data

      assert_equal @team, data[:unit_id]
      assert_equal "Payments", data[:name]
      assert_equal level_id("Team"), data[:level_id]
      assert_equal "espalia", data[:provider]
      assert_nil data[:external_ref]
      assert_equal "2026-11-01", data[:effective_on]
    end

    should "require a mirrored unit to carry the provider's reference" do
      assert_raises(ArgumentError) { create_unit(@department, "Engineering", level: "Department", provider: "hibob") }
    end

    should "refuse a second live unit mirroring the same reference" do
      create_unit(@department, "Engineering", level: "Department", provider: "hibob", external_ref: "dept-7")

      assert_raises(RuntimeError) do
        create_unit(SecureRandom.uuid_v7, "Eng", level: "Department", provider: "hibob", external_ref: "dept-7")
      end
    end

    should "refuse a parent at the same or a lower level" do
      create_unit(@team, "Payments", level: "Team")

      assert_raises(RuntimeError) { create_unit(SecureRandom.uuid_v7, "Ledger", level: "Team", parent_id: @team) }
      assert_raises(RuntimeError) { create_unit(SecureRandom.uuid_v7, "Finance", level: "Department", parent_id: @team) }
    end

    should "let a unit Espalia holds hang beneath a mirrored one, but not the reverse" do
      create_unit(@department, "Engineering", level: "Department", provider: "hibob", external_ref: "dept-7")
      create_unit(@team, "Payments", level: "Team", parent_id: @department)

      assert_raises(RuntimeError) do
        create_unit(@squad, "Checkout", level: "Squad", parent_id: @team, provider: "hibob", external_ref: "sq-1")
      end
    end

    should "refuse a unit id that isn't a UUID, or a date that isn't one" do
      assert_raises(ArgumentError) { create_unit("eng-1", "Engineering", level: "Department") }
      assert_raises(ArgumentError) do
        as_tenant { @handler.create_unit(@team, "Payments", level_id: level_id("Team"), effective_on: 20261101) }
      end
    end

    should "treat a UUID in upper case as the same unit" do
      create_unit(@team, "Payments", level: "Team")

      assert_raises(RuntimeError) { create_unit(@team.upcase, "Payments again", level: "Team") }
      as_tenant { @handler.rename_unit(@team.upcase, "Money", effective_on: @today) }
      assert_equal @team, structure_events.last.data[:unit_id]
    end

    should "refuse an unknown provider" do
      assert_raises(ArgumentError) do
        create_unit(@department, "Engineering", level: "Department", provider: "workday", external_ref: "d-1")
      end
    end

    should "keep the levels an HRIS supplies above every level Espalia holds, even at the top" do
      create_unit(@team, "Payments", level: "Team")

      assert_raises(RuntimeError) do
        create_unit(@department, "Engineering", level: "Squad", provider: "hibob", external_ref: "d-1")
      end
      assert_raises(RuntimeError) do
        create_unit(@squad, "Checkout", level: "Team", provider: "hibob", external_ref: "t-1")
      end
      create_unit(@department, "Engineering", level: "Department", provider: "hibob", external_ref: "d-1")
    end

    should "keep a unit Espalia holds below every level the HRIS supplies, even at the top" do
      create_unit(@team, "Payments", level: "Team", provider: "hibob", external_ref: "t-1")

      assert_raises(RuntimeError) { create_unit(@department, "Engineering", level: "Department") }
      assert_raises(RuntimeError) { create_unit(@squad, "Ledger", level: "Team") }
      create_unit(@squad, "Checkout", level: "Squad")
    end

    should "refuse a level outside the taxonomy" do
      assert_raises(RuntimeError) do
        as_tenant { @handler.create_unit(@team, "Payments", level_id: SecureRandom.uuid_v7, effective_on: @today) }
      end
    end
  end

  context "#rename_unit" do
    setup { create_unit(@team, "Payments", level: "Team") }

    should "keep the unit's id and record what it was called" do
      as_tenant { @handler.rename_unit(@team, "Money", effective_on: @today + 3, renamed_by_id: @actor) }
      data = structure_events.last.data

      assert_equal @team, data[:unit_id]
      assert_equal "Money", data[:name]
      assert_equal "Payments", data[:previous_name]
      assert_equal "2026-11-04", data[:effective_on]
    end

    should "write nothing for an unchanged name" do
      assert_no_difference -> { structure_events.size } do
        as_tenant { @handler.rename_unit(@team, "Payments ", effective_on: @today) }
      end
    end
  end

  context "a unit another provider supplies" do
    setup do
      create_unit(@department, "Engineering", level: "Department", provider: "hibob", external_ref: "dept-7")
      create_unit(SecureRandom.uuid_v7.tap { |id| @product = id }, "Product", level: "Department",
                  provider: "hibob", external_ref: "dept-8")
    end

    should "reject edits made in Espalia" do
      as_tenant do
        assert_raises(RuntimeError) { @handler.rename_unit(@department, "Eng", effective_on: @today) }
        assert_raises(RuntimeError) { @handler.retire_unit(@department, effective_on: @today) }
      end
    end

    should "accept a change from its own provider" do
      as_tenant { @handler.rename_unit(@department, "Engineering & Data", effective_on: @today, provider: "hibob") }

      assert_equal "Engineering & Data", structure_events.last.data[:name]
    end

    should "reject a move made in Espalia" do
      create_unit(@team, "Payments", level: "Team", parent_id: @department, provider: "hibob", external_ref: "t-1")

      assert_raises(RuntimeError) do
        as_tenant { @handler.move_unit(@team, @product, effective_on: @today) }
      end
    end
  end

  context "#move_unit" do
    setup do
      create_unit(@department, "Engineering", level: "Department")
      create_unit(@team, "Payments", level: "Team", parent_id: @department)
      create_unit(@squad, "Checkout", level: "Squad", parent_id: @team)
    end

    should "record the new parent, the old one and the date" do
      product = SecureRandom.uuid_v7
      create_unit(product, "Product", level: "Department")
      as_tenant { @handler.move_unit(@team, product, effective_on: @today + 10) }
      data = structure_events.last.data

      assert_equal product, data[:parent_id]
      assert_equal @department, data[:previous_parent_id]
      assert_equal "2026-11-11", data[:effective_on]
    end

    should "move a unit to the top" do
      as_tenant { @handler.move_unit(@team, nil, effective_on: @today) }

      assert_nil structure_events.last.data[:parent_id]
    end

    should "refuse to move a unit beneath itself or a unit beneath it" do
      as_tenant do
        assert_raises(RuntimeError) { @handler.move_unit(@team, @team, effective_on: @today) }
        assert_raises(RuntimeError) { @handler.move_unit(@team, @squad, effective_on: @today) }
      end
    end
  end

  context "#retire_unit" do
    setup do
      create_unit(@department, "Engineering", level: "Department")
      create_unit(@team, "Payments", level: "Team", parent_id: @department)
    end

    should "refuse while a live unit sits beneath it" do
      assert_raises(RuntimeError) { as_tenant { @handler.retire_unit(@department, effective_on: @today) } }
    end

    should "retire a leaf, then refuse further edits" do
      as_tenant do
        @handler.retire_unit(@team, effective_on: @today, retired_by_id: @actor)

        assert_kind_of OrgGraph::Events::UnitRetired, structure_events.last
        assert_raises(RuntimeError) { @handler.rename_unit(@team, "Money", effective_on: @today) }
        @handler.retire_unit(@department, effective_on: @today)
      end
    end
  end

  context "#record_succession" do
    setup do
      @payments = SecureRandom.uuid_v7
      @billing = SecureRandom.uuid_v7
      @ledger = SecureRandom.uuid_v7
      create_unit(@department, "Engineering", level: "Department")
      [ [ @payments, "Payments" ], [ @billing, "Billing" ], [ @ledger, "Ledger" ] ].each do |id, name|
        create_unit(id, name, level: "Team", parent_id: @department)
      end
    end

    should "record a split, a merge and a replacement, each as one stated link" do
      split = succeed([ @payments ], [ @billing, @ledger ])
      merge = succeed([ @billing, @ledger ], [ create_unit(SecureRandom.uuid_v7, "Money", level: "Team") ])
      replacement = succeed([ @department ], [ create_unit(SecureRandom.uuid_v7, "Platform", level: "Department") ])

      events = structure_events.select { |event| event.is_a?(OrgGraph::Events::UnitSucceeded) }
      assert_equal [ split, merge, replacement ], events.map { |event| event.data[:succession_id] }
      assert_equal [ @payments ], events.first.data[:predecessor_ids]
      assert_equal [ @billing, @ledger ].sort, events.first.data[:successor_ids]
      assert_equal [ @billing, @ledger ].sort, events.second.data[:predecessor_ids]
      assert_equal "2026-11-01", events.first.data[:effective_on]
    end

    should "retire the predecessors through the succession when asked, naming it and the successors" do
      id = succeed([ @billing, @ledger ], [ @payments ], retire_predecessors: true, stated_by_id: @actor)

      retirements = structure_events.last(2)
      assert(retirements.all?(OrgGraph::Events::UnitRetired))
      assert_equal [ @billing, @ledger ].sort, retirements.map { |event| event.data[:unit_id] }.sort
      assert(retirements.all? { |event| event.data[:succession_id] == id })
      assert(retirements.all? { |event| event.data[:successor_ids] == [ @payments ] })
      assert(retirements.all? { |event| event.data[:retired_by_id] == @actor })
    end

    should "retire a predecessor's sub-units before it when they retire together" do
      platform = create_unit(SecureRandom.uuid_v7, "Platform", level: "Department")
      as_tenant do
        [ @billing, @ledger ].each { |id| @handler.move_unit(id, platform, effective_on: @today) }
      end

      succeed([ @department, @payments ], [ platform ], retire_predecessors: true)

      assert_equal [ @payments, @department ], structure_events.last(2).map { |event| event.data[:unit_id] }
    end

    should "leave a plain retirement and a new unit unlinked" do
      as_tenant { @handler.retire_unit(@ledger, effective_on: @today) }
      create_unit(SecureRandom.uuid_v7, "Ledger 2", level: "Team", parent_id: @department)

      assert_not(structure_events.any?(OrgGraph::Events::UnitSucceeded))
      assert_nil structure_events.reverse.find { |event| event.is_a?(OrgGraph::Events::UnitRetired) }.data[:succession_id]
    end

    should "let someone state a link after the predecessor has retired" do
      as_tenant { @handler.retire_unit(@ledger, effective_on: @today) }

      succeed([ @ledger ], [ @billing ])

      assert_kind_of OrgGraph::Events::UnitSucceeded, structure_events.last
    end

    should "write nothing when the same succession is stated again" do
      id = succeed([ @payments ], [ @billing ])

      assert_no_difference(-> { structure_events.size }) { succeed([ @payments ], [ @billing.upcase ], id: id) }
      assert_raises(RuntimeError) { succeed([ @payments ], [ @ledger ], id: id) }
    end

    should "refuse a unit succeeding itself, a missing or retired successor, or an empty side" do
      as_tenant { @handler.retire_unit(@ledger, effective_on: @today) }

      assert_raises(ArgumentError) { succeed([ @payments ], [ @payments, @billing ]) }
      assert_raises(RuntimeError) { succeed([ @payments ], [ SecureRandom.uuid_v7 ]) }
      assert_raises(RuntimeError) { succeed([ @payments ], [ @ledger ]) }
      assert_raises(ArgumentError) { succeed([], [ @billing ]) }
      assert_raises(ArgumentError) { succeed([ @payments ], [ "billing" ]) }
    end

    should "refuse a succession that loops back" do
      succeed([ @payments ], [ @billing ])
      succeed([ @billing ], [ @ledger ])

      assert_raises(RuntimeError) { succeed([ @ledger ], [ @payments ]) }
    end

    should "retire only the predecessors whose provider states it" do
      as_tenant { [ @payments, @billing, @ledger, @department ].each { |id| @handler.retire_unit(id, effective_on: @today) } }
      product = create_unit(SecureRandom.uuid_v7, "Product", level: "Department", provider: "hibob", external_ref: "d-8")
      design = create_unit(SecureRandom.uuid_v7, "Design", level: "Department", provider: "hibob", external_ref: "d-9")

      assert_raises(RuntimeError) { succeed([ product ], [ design ], retire_predecessors: true) }
      succeed([ product ], [ design ], retire_predecessors: true, provider: "hibob")

      assert_equal "hibob", structure_events.last.data[:provider]
    end

    should "refuse to retire a predecessor that still holds sub-units outside the succession" do
      assert_raises(RuntimeError) do
        succeed([ @department ], [ create_unit(SecureRandom.uuid_v7, "Platform", level: "Department") ],
                retire_predecessors: true)
      end
    end
  end

  private

  def as_tenant(&block)
    ActsAsTenant.with_tenant(@tenant, &block)
  end

  def levels(names)
    @level_ids ||= {}
    names.map { |name| { level_id: (@level_ids[name.strip.downcase] ||= SecureRandom.uuid_v7), name: name } }
  end

  def level_id(name)
    @level_ids.fetch(name.downcase)
  end

  def create_unit(unit_id, name, level:, **options)
    as_tenant do
      @handler.create_unit(unit_id, name, level_id: level_id(level), effective_on: @today, **options)
    end
    unit_id
  end

  def succeed(predecessor_ids, successor_ids, id: SecureRandom.uuid_v7, **options)
    as_tenant do
      @handler.record_succession(id, predecessor_ids:, successor_ids:, effective_on: @today, **options)
    end
    id
  end

  def structure_events
    Rails.configuration.event_store.read.stream(EventStreamNaming.org_structure_stream(tenant: @tenant)).to_a
  end
end
