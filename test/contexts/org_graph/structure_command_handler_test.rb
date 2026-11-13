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
      provide("Department", "hibob")
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

    should "let a unit Espalia holds hang beneath a mirrored one" do
      provide("Department", "hibob")
      create_unit(@department, "Engineering", level: "Department", provider: "hibob", external_ref: "dept-7")
      create_unit(@team, "Payments", level: "Team", parent_id: @department)

      assert_equal @department, structure_events.last.data[:parent_id]
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

    should "take a unit only from its level's provider" do
      provide("Department", "hibob")

      error = assert_raises(RuntimeError) { create_unit(@department, "Engineering", level: "Department") }
      assert_match "hibob supplies this level", error.message
      assert_raises(RuntimeError) { create_unit(@team, "Payments", level: "Team", provider: "hibob", external_ref: "t-1") }
      create_unit(@department, "Engineering", level: "Department", provider: "hibob", external_ref: "d-1")
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
      provide("Department", "hibob")
      provide("Team", "hibob")
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

  context "#set_level_provider" do
    should "record the provider, the one it replaced, the date and who set it" do
      provide("Department", "hibob", set_by_id: @actor)
      event = structure_events.last

      assert_kind_of OrgGraph::Events::LevelProviderSet, event
      assert_equal level_id("Department"), event.data[:level_id]
      assert_equal "hibob", event.data[:provider]
      assert_equal "espalia", event.data[:previous_provider]
      assert_equal "2026-11-01", event.data[:effective_on]
      assert_equal @actor, event.data[:set_by_id]
    end

    should "write nothing for an unchanged provider, Espalia included" do
      provide("Department", "hibob")

      assert_no_difference -> { structure_events.size } do
        provide("Department", "hibob")
        provide("Team", "espalia")
      end
    end

    should "keep the levels an HRIS provides above every level Espalia holds" do
      error = assert_raises(RuntimeError) { provide("Team", "hibob") }
      assert_match "must sit above", error.message

      provide("Department", "hibob")
      provide("Team", "hibob")
      assert_raises(RuntimeError) { provide("Department", "espalia") }
      provide("Team", "espalia")
    end

    should "refuse a level that still holds live units, which would be a handover" do
      create_unit(@department, "Engineering", level: "Department")

      error = assert_raises(RuntimeError) { provide("Department", "hibob") }
      assert_match "hand it over", error.message
    end

    should "allow it once the level's units are retired" do
      create_unit(@department, "Engineering", level: "Department")
      as_tenant { @handler.retire_unit(@department, effective_on: @today) }

      provide("Department", "hibob")
      assert_equal "hibob", structure_events.last.data[:provider]
    end

    should "refuse a level outside the taxonomy or an unknown provider" do
      assert_raises(RuntimeError) do
        as_tenant { @handler.set_level_provider(SecureRandom.uuid_v7, "hibob", effective_on: @today) }
      end
      assert_raises(ArgumentError) { provide("Department", "workday") }
    end

    should "hold through a redefinition, and refuse one that puts an Espalia level on top" do
      provide("Department", "hibob")
      renamed = [ { level_id: level_id("Department"), name: "Division" }, *levels(%w[Team Squad]) ]
      as_tenant { @handler.define_taxonomy(renamed, effective_on: @today) }

      assert_raises(RuntimeError) { create_unit(@department, "Engineering", level: "Department") }
      assert_raises(RuntimeError) do
        as_tenant { @handler.define_taxonomy(levels(%w[Group]) + renamed, effective_on: @today) }
      end
    end
  end

  context "#define_taxonomy with a new level's provider" do
    setup do
      provide("Department", "hibob")
      create_unit(@department, "Engineering", level: "Department", provider: "hibob", external_ref: "d-1")
    end

    should "add a level above one an HRIS provides, setting its provider in the same change" do
      division = SecureRandom.uuid_v7
      as_tenant do
        @handler.define_taxonomy([ { level_id: division, name: "Division", provider: "hibob" }, *levels(%w[Department Team Squad]) ],
                                 effective_on: @today + 1, defined_by_id: @actor)
      end
      taxonomy, provider = structure_events.last(2)

      assert_kind_of OrgGraph::Events::TaxonomyDefined, taxonomy
      assert_equal %w[level_id name], taxonomy.data[:levels].first.keys.map(&:to_s)
      assert_kind_of OrgGraph::Events::LevelProviderSet, provider
      assert_equal({ level_id: division, provider: "hibob", previous_provider: "espalia", effective_on: "2026-11-02", set_by_id: @actor },
                   provider.data.slice(:level_id, :provider, :previous_provider, :effective_on, :set_by_id))
    end

    should "refuse a new level above it that names no provider" do
      assert_raises(RuntimeError) do
        as_tenant { @handler.define_taxonomy([ { level_id: SecureRandom.uuid_v7, name: "Division" }, *levels(%w[Department Team Squad]) ], effective_on: @today) }
      end
    end

    should "refuse a different provider for a level it already holds" do
      changed = levels(%w[Department Team Squad]).tap { |all| all[0] = all[0].merge(provider: "espalia") }

      error = assert_raises(RuntimeError) { as_tenant { @handler.define_taxonomy(changed, effective_on: @today) } }
      assert_match "set_level_provider", error.message
    end
  end

  context "#set_fact_provider" do
    should "record the fact's provider, the one it replaced, the date and who set it" do
      as_tenant { @handler.set_fact_provider(:title, "hibob", effective_on: @today, set_by_id: @actor) }
      event = structure_events.last

      assert_kind_of OrgGraph::Events::FactProviderSet, event
      assert_equal({ fact: "title", provider: "hibob", previous_provider: "espalia",
                     effective_on: "2026-11-01", set_by_id: @actor }, event.data.slice(:fact, :provider, :previous_provider, :effective_on, :set_by_id))
    end

    should "give each fact one provider, and write nothing when it is unchanged" do
      as_tenant do
        @handler.set_fact_provider("title", "hibob", effective_on: @today)
        @handler.set_fact_provider("title", "espalia", effective_on: @today + 1)

        assert_equal "hibob", structure_events.last.data[:previous_provider]
        assert_no_difference -> { structure_events.size } do
          @handler.set_fact_provider("title", "espalia", effective_on: @today + 2)
        end
      end
    end

    should "keep the fields an HRIS reads a fact from in the same event as its provider" do
      as_tenant do
        @handler.set_fact_provider(:cost_centre, "hibob", fields: { cost_centre: " work.customColumns.column_1 " },
                                                          effective_on: @today)
      end

      assert_equal({ "cost_centre" => "work.customColumns.column_1" }, structure_events.last.data[:fields])
    end

    should "keep the fields when the same provider is restated, and write when only they change" do
      as_tenant do
        @handler.set_fact_provider("site", "hibob", fields: { country: "address.country" }, effective_on: @today)

        assert_no_difference -> { structure_events.size } do
          @handler.set_fact_provider("site", "hibob", effective_on: @today + 1)
        end

        @handler.set_fact_provider("site", "hibob", fields: { country: "work.customColumns.column_2" }, effective_on: @today + 1)
        assert_equal({ "country" => "work.customColumns.column_2" }, structure_events.last.data[:fields])

        @handler.set_fact_provider("site", "hibob", fields: {}, effective_on: @today + 2)
        assert_equal({}, structure_events.last.data[:fields])
      end
    end

    should "clear the fields when the fact moves to another provider" do
      as_tenant do
        @handler.set_fact_provider("site", "hibob", fields: { country: "address.country" }, effective_on: @today)
        @handler.set_fact_provider("site", "espalia", effective_on: @today + 1)
      end

      assert_equal({}, structure_events.last.data[:fields])
    end

    should "read a setting from before fields as having none" do
      as_tenant do
        Rails.configuration.event_store.publish(
          OrgGraph::Events::FactProviderSet.new(data: { fact: "site", provider: "hibob", previous_provider: "espalia",
                                                        effective_on: "2026-01-01", set_by_id: nil },
                                                metadata: { tenant_id: @tenant.id }),
          stream_name: EventStreamNaming.org_structure_stream(tenant: @tenant)
        )

        assert_no_difference -> { structure_events.size } do
          @handler.set_fact_provider("site", "hibob", fields: {}, effective_on: @today)
        end
      end
    end

    should "refuse a field for Espalia, for a part no field can supply, or with no path" do
      as_tenant do
        assert_raises(ArgumentError) { @handler.set_fact_provider("cost_centre", "espalia", fields: { cost_centre: "x" }, effective_on: @today) }
        assert_raises(ArgumentError) { @handler.set_fact_provider("site", "hibob", fields: { site: "work.site" }, effective_on: @today) }
        assert_raises(ArgumentError) { @handler.set_fact_provider("title", "hibob", fields: { title: "work.title" }, effective_on: @today) }
        assert_raises(ArgumentError) { @handler.set_fact_provider("cost_centre", "hibob", fields: { cost_centre: " " }, effective_on: @today) }
      end
    end

    should "write a first choice of Espalia once, so a later claim knows someone chose" do
      as_tenant do
        assert_difference -> { structure_events.size }, 1 do
          @handler.set_fact_provider("manager", "espalia", effective_on: @today)
          @handler.set_fact_provider("manager", "espalia", effective_on: @today + 1)
        end
        assert_equal %w[espalia espalia], structure_events.last.data.values_at(:provider, :previous_provider)
        assert_equal [], @handler.claim_facts(%w[manager], "hibob", effective_on: @today)
      end
    end

    should "refuse an unknown fact or provider" do
      as_tenant do
        assert_raises(ArgumentError) { @handler.set_fact_provider("salary", "hibob", effective_on: @today) }
        assert_raises(ArgumentError) { @handler.set_fact_provider("title", "workday", effective_on: @today) }
      end
    end
  end

  context "unit owners" do
    setup do
      create_unit(@team, "Payments", level: "Team")
      @owner = SecureRandom.uuid_v7
    end

    should "record who owns the unit, from when, and who named them" do
      as_tenant { @handler.add_unit_owner(@team, @owner, effective_on: @today, added_by_id: @actor) }
      event = structure_events.last

      assert_kind_of OrgGraph::Events::UnitOwnerAdded, event
      assert_equal({ unit_id: @team, person_id: @owner, effective_on: "2026-11-01", added_by_id: @actor },
                   event.data.slice(:unit_id, :person_id, :effective_on, :added_by_id))
    end

    should "take several owners, none primary, and write nothing for one it already has" do
      as_tenant do
        @handler.add_unit_owner(@team, @owner, effective_on: @today)
        @handler.add_unit_owner(@team, @actor, effective_on: @today)

        assert_no_difference -> { structure_events.size } do
          @handler.add_unit_owner(@team, @owner.upcase, effective_on: @today + 1)
        end
      end
    end

    should "remove an owner, and write nothing for someone who isn't one" do
      as_tenant do
        @handler.add_unit_owner(@team, @owner, effective_on: @today)
        @handler.remove_unit_owner(@team, @owner, effective_on: @today + 5, removed_by_id: @actor)

        assert_kind_of OrgGraph::Events::UnitOwnerRemoved, structure_events.last
        assert_equal "2026-11-06", structure_events.last.data[:effective_on]
        assert_no_difference -> { structure_events.size } do
          @handler.remove_unit_owner(@team, @owner, effective_on: @today + 6)
        end
      end
    end

    should "name an owner for a unit an HRIS supplies, since Espalia states ownership" do
      provide("Department", "hibob")
      create_unit(@department, "Engineering", level: "Department", provider: "hibob", external_ref: "d-1")

      as_tenant { @handler.add_unit_owner(@department, @owner, effective_on: @today) }
      assert_equal @department, structure_events.last.data[:unit_id]
    end

    should "refuse a retired or unknown unit, or an owner id that isn't a UUID" do
      as_tenant do
        @handler.retire_unit(@team, effective_on: @today)

        assert_raises(RuntimeError) { @handler.add_unit_owner(@team, @owner, effective_on: @today) }
        assert_raises(RuntimeError) { @handler.add_unit_owner(SecureRandom.uuid_v7, @owner, effective_on: @today) }
        @handler.create_unit(@squad, "Checkout", level_id: level_id("Squad"), effective_on: @today)
        assert_raises(ArgumentError) { @handler.add_unit_owner(@squad, "alice", effective_on: @today) }
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
      assert_raises(RuntimeError) do
        as_tenant do
          @handler.record_succession(id, predecessor_ids: [ @payments ], successor_ids: [ @billing ], effective_on: @today + 1)
        end
      end
    end

    should "retire the predecessors when a stated succession is restated with retirement" do
      id = succeed([ @payments ], [ @billing ])

      succeed([ @payments ], [ @billing ], id: id, retire_predecessors: true)

      assert_equal [ OrgGraph::Events::UnitSucceeded, OrgGraph::Events::UnitRetired ], structure_events.last(2).map(&:class)
      assert_equal id, structure_events.last.data[:succession_id]
    end

    should "refuse to retire through a restated succession whose successor has since retired" do
      id = succeed([ @payments ], [ @billing ])
      as_tenant { @handler.retire_unit(@billing, effective_on: @today) }

      succeed([ @payments ], [ @billing ], id: id)
      assert_raises(RuntimeError) { succeed([ @payments ], [ @billing ], id: id, retire_predecessors: true) }
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
      provide("Department", "hibob")
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

  context "#claim_facts" do
    should "hand each unset fact to the provider and report what it claimed" do
      claimed = as_tenant { @handler.claim_facts(%w[title level], "hibob", effective_on: @today, set_by_id: @actor) }

      assert_equal %w[title level], claimed
      assert_equal %w[title level], structure_events.select { it.is_a?(OrgGraph::Events::FactProviderSet) }.map { it.data[:fact] }
      as_tenant { assert_equal "hibob", OrgFactProvider.provider_for("level") }
    end

    should "leave a fact whose provider was ever chosen, so a re-run only reaches new facts" do
      as_tenant do
        @handler.claim_facts(%w[title], "hibob", effective_on: @today)
        @handler.set_fact_provider("title", "espalia", effective_on: @today)

        assert_equal %w[site], @handler.claim_facts(%w[title site], "hibob", effective_on: @today)
        assert_equal [], @handler.claim_facts(%w[title site], "hibob", effective_on: @today)
        assert_equal "espalia", OrgFactProvider.provider_for("title")
      end
    end

    should "refuse a fact it doesn't know" do
      assert_raises(ArgumentError) { as_tenant { @handler.claim_facts(%w[department], "hibob", effective_on: @today) } }
    end
  end

  context "effective dates" do
    setup do
      create_unit(@department, "Engineering", level: "Department")
      create_unit(@team, "Payments", level: "Team", parent_id: @department)
    end

    should "refuse a change dated before the unit was created" do
      as_tenant do
        assert_raises(RuntimeError, match: /created on 2026-11-01/) do
          @handler.rename_unit(@team, "Billing", effective_on: "2026-10-31")
        end
        assert_raises(RuntimeError, match: /created on 2026-11-01/) do
          @handler.move_unit(@team, nil, effective_on: "2026-10-31")
        end
      end
    end

    should "accept a backdated change after creation, and refuse a retirement before it" do
      as_tenant do
        @handler.rename_unit(@team, "Billing", effective_on: "2026-12-01")
        @handler.move_unit(@team, nil, effective_on: "2026-11-15")

        assert_equal "2026-11-15", structure_events.last.data[:effective_on]
        assert_raises(RuntimeError, match: /retire before its last change on 2026-12-01/) do
          @handler.retire_unit(@team, effective_on: "2026-11-20")
        end
        assert_nothing_raised { @handler.retire_unit(@team, effective_on: "2026-12-01") }
      end
    end

    should "refuse a retirement dated before an owner was added or removed" do
      owner = SecureRandom.uuid_v7
      as_tenant do
        @handler.add_unit_owner(@team, owner, effective_on: "2026-12-01")

        assert_raises(RuntimeError, match: /retire before its last change on 2026-12-01/) do
          @handler.retire_unit(@team, effective_on: "2026-11-15")
        end

        @handler.remove_unit_owner(@team, owner, effective_on: "2026-12-10")
        assert_raises(RuntimeError, match: /retire before its last change on 2026-12-10/) do
          @handler.retire_unit(@team, effective_on: "2026-12-05")
        end
      end
    end

    should "refuse to place a unit beneath a parent before the parent existed" do
      later = SecureRandom.uuid_v7
      as_tenant do
        @handler.create_unit(later, "Platform", level_id: level_id("Department"), effective_on: "2027-01-01")

        assert_raises(RuntimeError, match: /parent unit was created on 2027-01-01/) do
          @handler.create_unit(@squad, "Ledger", level_id: level_id("Squad"), parent_id: later, effective_on: "2026-12-01")
        end
        assert_raises(RuntimeError, match: /parent unit was created on 2027-01-01/) do
          @handler.move_unit(@team, later, effective_on: "2026-12-01")
        end
        assert_nothing_raised { @handler.move_unit(@team, later, effective_on: "2027-01-01") }
      end
    end

    should "refuse to retire a unit before a sub-unit arrived beneath it or left" do
      later = SecureRandom.uuid_v7
      as_tenant do
        @handler.create_unit(@squad, "Ledger", level_id: level_id("Squad"), parent_id: @team, effective_on: "2026-12-01")
        @handler.create_unit(later, "Treasury", level_id: level_id("Team"), parent_id: @department, effective_on: "2026-11-01")
        @handler.move_unit(@squad, later, effective_on: "2027-01-01")

        assert_raises(RuntimeError, match: /last change on 2027-01-01/) do
          @handler.retire_unit(@team, effective_on: "2026-12-15")
        end
        assert_nothing_raised { @handler.retire_unit(@team, effective_on: "2027-01-01") }
      end
    end

    should "refuse to retire a unit before its last sub-unit retired" do
      as_tenant do
        @handler.create_unit(@squad, "Ledger", level_id: level_id("Squad"), parent_id: @team, effective_on: "2026-11-01")
        @handler.retire_unit(@squad, effective_on: "2027-03-01")

        assert_raises(RuntimeError, match: /last change on 2027-03-01/) do
          @handler.retire_unit(@team, effective_on: "2027-02-01")
        end
      end
    end

    should "refuse a succession dated before a unit it names was created" do
      successor = SecureRandom.uuid_v7
      as_tenant do
        @handler.create_unit(successor, "Ledger", level_id: level_id("Team"), parent_id: @department, effective_on: "2027-02-01")

        assert_raises(RuntimeError, match: /can't predate Ledger, created on 2027-02-01/) do
          @handler.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @team ], successor_ids: [ successor ],
                                     effective_on: "2026-12-01")
        end
      end
    end

    should "refuse a succession that retires a predecessor before its last change" do
      successor = SecureRandom.uuid_v7
      create_unit(successor, "Ledger", level: "Team", parent_id: @department)
      as_tenant do
        @handler.rename_unit(@team, "Billing", effective_on: "2026-12-01")

        assert_raises(RuntimeError, match: /last change on 2026-12-01/) do
          @handler.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @team ], successor_ids: [ successor ],
                                     effective_on: "2026-11-15", retire_predecessors: true)
        end
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

  def provide(level, provider, **options)
    as_tenant { @handler.set_level_provider(level_id(level), provider, effective_on: @today, **options) }
  end

  def structure_events
    Rails.configuration.event_store.read.stream(EventStreamNaming.org_structure_stream(tenant: @tenant)).to_a
  end
end
