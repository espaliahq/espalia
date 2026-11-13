# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class OrgGraph::Projections::StructureTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  setup do
    @tenant = create(:tenant)
    @handler = OrgGraph::StructureCommandHandler.new
    @department_level = SecureRandom.uuid_v7
    @team_level = SecureRandom.uuid_v7
    @engineering = SecureRandom.uuid_v7
    @product = SecureRandom.uuid_v7
    @payments = SecureRandom.uuid_v7

    as_tenant do
      @handler.define_taxonomy(taxonomy("Department", "Team"), effective_on: "2026-01-01")
      @handler.create_unit(@engineering, "Engineering", level_id: @department_level, effective_on: "2026-01-01",
                           provider: "hibob", external_ref: "dept-7")
      @handler.create_unit(@product, "Product", level_id: @team_level, effective_on: "2026-01-01")
      @handler.create_unit(@payments, "Payments", level_id: @team_level, parent_id: @engineering, effective_on: "2026-02-01")
    end
  end

  context "the taxonomy" do
    should "list the levels top first" do
      as_tenant { assert_equal %w[Department Team], OrgTaxonomyLevel.top_first.pluck(:name) }
    end

    should "follow a redefinition, keeping a renamed level's id" do
      squad_level = SecureRandom.uuid_v7
      as_tenant do
        @handler.define_taxonomy([ *taxonomy("Division", "Team"), { level_id: squad_level, name: "Squad" } ],
                                 effective_on: "2026-03-01")

        assert_equal %w[Division Team Squad], OrgTaxonomyLevel.top_first.pluck(:name)
        assert_equal "Division", OrgTaxonomyLevel.find(@department_level).name
        assert_equal Date.new(2026, 3, 1), OrgTaxonomyLevel.find(@department_level).effective_on
        assert_equal Date.new(2026, 1, 1), OrgTaxonomyLevel.find(@team_level).effective_on
      end
    end
  end

  context "the unit tree" do
    should "place each unit under its parent, with its provider and reference" do
      as_tenant do
        assert_equal [ @payments ], OrgUnit.find(@engineering).children.map(&:id)
        assert_equal "dept-7", OrgUnit.find(@engineering).external_ref
        assert_not OrgUnit.find(@engineering).held_by_espalia?
        assert OrgUnit.find(@product).held_by_espalia?
        assert_equal [ @engineering, @product ].sort, OrgUnit.live.roots.pluck(:id).sort
      end
    end

    should "keep a renamed unit's row and date the new name" do
      as_tenant do
        @handler.rename_unit(@product, "Product & Design", effective_on: "2026-04-01")
        unit = OrgUnit.find(@product)

        assert_equal "Product & Design", unit.name
        assert_equal Date.new(2026, 4, 1), unit.name_effective_on
        assert_equal Date.new(2026, 1, 1), unit.created_on
      end
    end

    should "date a move separately from the name" do
      as_tenant do
        @handler.move_unit(@payments, nil, effective_on: "2026-05-01")
        unit = OrgUnit.find(@payments)

        assert_nil unit.parent_id
        assert_equal Date.new(2026, 5, 1), unit.parent_effective_on
        assert_equal Date.new(2026, 2, 1), unit.name_effective_on
      end
    end

    should "keep a retired unit with the date it ended" do
      as_tenant do
        @handler.retire_unit(@payments, effective_on: "2026-06-30")

        assert_equal Date.new(2026, 6, 30), OrgUnit.find(@payments).retired_on
        assert_not_includes OrgUnit.live.pluck(:id), @payments
      end
    end
  end

  context "succession" do
    setup do
      @billing = SecureRandom.uuid_v7
      @ledger = SecureRandom.uuid_v7
      as_tenant do
        [ [ @billing, "Billing" ], [ @ledger, "Ledger" ] ].each do |id, name|
          @handler.create_unit(id, name, level_id: @team_level, parent_id: @engineering, effective_on: "2026-07-01")
        end
      end
    end

    should "let a reader list a split unit's successors and each successor's predecessor" do
      as_tenant do
        @handler.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @payments ], successor_ids: [ @billing, @ledger ],
                                                         effective_on: "2026-07-01", retire_predecessors: true)

        assert_equal [ @billing, @ledger ].sort, OrgUnit.find(@payments).successors.pluck(:id).sort
        assert_equal [ @payments ], OrgUnit.find(@ledger).predecessors.pluck(:id)
        assert OrgUnit.find(@payments).retired?
        assert_equal Date.new(2026, 7, 1), OrgUnit.find(@billing).predecessor_links.sole.effective_on
      end
    end

    should "let a reader list a merged unit's predecessors" do
      as_tenant do
        @handler.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @billing, @ledger ], successor_ids: [ @payments ],
                                                         effective_on: "2026-08-01")

        assert_equal [ @billing, @ledger ].sort, OrgUnit.find(@payments).predecessors.pluck(:id).sort
        assert_empty OrgUnit.find(@payments).successors
      end
    end

    should "list a predecessor once when two successions link the same pair" do
      as_tenant do
        @handler.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @billing ], successor_ids: [ @payments ],
                                                         effective_on: "2026-08-01")
        @handler.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @billing, @ledger ], successor_ids: [ @payments ],
                                                         effective_on: "2026-09-01")

        assert_equal [ @billing, @ledger ].sort, OrgUnit.find(@payments).predecessors.pluck(:id).sort
      end
    end
  end

  context "rebuild contract" do
    should "reset! + replay produce identical read-model state, including the stable ids" do
      as_tenant do
        @handler.rename_unit(@engineering, "Engineering & Data", effective_on: "2026-03-01", provider: "hibob")
        @handler.move_unit(@payments, nil, effective_on: "2026-04-01")
        @handler.define_taxonomy(taxonomy("Division", "Team"), effective_on: "2026-05-01")
        @handler.retire_unit(@product, effective_on: "2026-06-01")
        @handler.create_unit(SecureRandom.uuid_v7.tap { |id| @billing = id }, "Billing", level_id: @team_level,
                             effective_on: "2026-07-01")
        @handler.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @payments, @product ], successor_ids: [ @billing ],
                                                         effective_on: "2026-07-01", retire_predecessors: true)
      end

      before = snapshot_read_models(OrgGraph::Projections::Structure, @tenant)
      assert_equal 2, before[:taxonomy_levels].size
      assert_equal 4, before[:units].size
      assert_equal 2, before[:successions].size

      OrgGraph::Projections::Structure.reset!(tenant: @tenant)
      as_tenant { assert_equal 0, OrgUnit.count + OrgTaxonomyLevel.count + OrgUnitSuccession.count }

      Projections::Replayer.replay(projection_class: OrgGraph::Projections::Structure, tenant: @tenant)

      assert_equal before, snapshot_read_models(OrgGraph::Projections::Structure, @tenant)
    end

    should "leave another tenant's structure alone on reset!" do
      other = create(:tenant)
      ActsAsTenant.with_tenant(other) do
        @handler.define_taxonomy([ { level_id: SecureRandom.uuid_v7, name: "Department" } ], effective_on: "2026-01-01")
      end

      OrgGraph::Projections::Structure.reset!(tenant: @tenant)

      ActsAsTenant.with_tenant(other) { assert_equal 1, OrgTaxonomyLevel.count }
    end
  end

  private

  def as_tenant(&block)
    ActsAsTenant.with_tenant(@tenant, &block)
  end

  def taxonomy(top, lower = nil)
    [ { level_id: @department_level, name: top }, ({ level_id: @team_level, name: lower } if lower) ].compact
  end
end
