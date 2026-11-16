# frozen_string_literal: true

require "test_helper"

# Every stream in production was written before kinds stated their rules.
# Replaying one must place units as the ordered levels did: a parent at a
# higher level, and never an Espalia unit above a mirrored one. The one
# narrowing is deliberate: a level an HRIS provides now takes a parent only
# from the HRIS level directly above it, the only place the mirror has ever
# put one. `org_graph:taxonomy:check` finds any unit sitting elsewhere.
class OrgGraph::KindRulesConversionTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @handler = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @today = Date.new(2026, 11, 1)
    @level_ids = {}
    build_legacy_stream
  end

  should "accept and refuse every placement as the ordered levels did, narrowed for mirrored units" do
    order = as_tenant { OrgTaxonomyLevel.top_first.pluck(:id) }
    providers = as_tenant { OrgTaxonomyLevel.pluck(:id, :provider).to_h }
    units = as_tenant { OrgUnit.where(retired_on: nil).to_a }
    assert_equal 9, units.size

    units.each do |unit|
      units.each do |parent|
        next if parent.id == unit.parent_id

        assert_equal legacy_allows?(unit, parent, order, providers), accepts_move?(unit, parent.id),
                     "#{unit.name} beneath #{parent.name}"
      end
    end
  end

  should "refuse a mirrored unit beneath an HRIS level other than the one directly above, which order allowed" do
    as_tenant { @handler.hand_over_level(id("Department"), "hibob", field: "work.department", matches: { @engineering => "eng", @marketing => "mkt" }, effective_on: @today) }
    region = as_tenant { unit("Region", "Department", parent_id: @ops, provider: "hibob", external_ref: "region") }
    as_tenant { @handler.hand_over_level(id("Team"), "hibob", field: "work.team", matches: { @payments => "pay", @lending => "lend", @platform => "plat" }, effective_on: @today) }

    error = assert_raises(RuntimeError) do
      as_tenant { @handler.move_unit(@lending, @ops, effective_on: @today, provider: "hibob") }
    end
    assert_equal "A parent must sit at a higher level", error.message
    assert_nothing_raised { as_tenant { @handler.move_unit(@lending, region, effective_on: @today, provider: "hibob") } }
  end

  should "let every live unit sit where it is, and every kind at the top" do
    structure = as_tenant { OrgGraph::Repository.new.load_structure }

    assert_empty structure.misplaced_units
    assert(structure.taxonomy.kinds.all?(&:top?))
  end

  private

  def build_legacy_stream
    as_tenant do
      @handler.define_taxonomy(levels(%w[Division Department Team Squad]), effective_on: @today)
      @handler.add_level(id("Guild"), "Guild", effective_on: @today)
      @handler.reorder_levels(%w[Division Department Squad Team Guild].map { id(it) }, effective_on: @today)
      @handler.reorder_levels(%w[Division Department Team Squad Guild].map { id(it) }, effective_on: @today)
      @handler.remove_level(id("Guild"), effective_on: @today)
      %w[Division Department].each { @handler.set_level_provider(id(it), "hibob", effective_on: @today, field: "work.#{it.downcase}") }

      @ops = unit("Ops", "Division", provider: "hibob", external_ref: "ops")
      @sales = unit("Sales", "Division", provider: "hibob", external_ref: "sales")
      @engineering = unit("Engineering", "Department", parent_id: @ops, provider: "hibob", external_ref: "eng")
      @marketing = unit("Marketing", "Department", parent_id: @sales, provider: "hibob", external_ref: "mkt")
      @payments = unit("Payments", "Team", parent_id: @engineering)
      @lending = unit("Lending", "Team")
      @platform = unit("Platform", "Team", parent_id: @ops)
      unit("Checkout", "Squad", parent_id: @payments)
      unit("Loans", "Squad", parent_id: @lending)

      @handler.hand_back_level(id("Department"), effective_on: @today)
    end
  end

  def legacy_allows?(unit, parent, order, providers)
    return false unless order.index(parent.level_id) < order.index(unit.level_id)
    return true if unit.provider == "espalia"

    parent.provider != "espalia" && order.index(parent.level_id) == order.index(unit.level_id) - 1 &&
      providers[parent.level_id] != "espalia"
  end

  def accepts_move?(unit, parent_id)
    as_tenant { OrgGraph::Repository.new.load_structure.move_unit(unit.id, parent_id, effective_on: @today, provider: unit.provider) }
    true
  rescue RuntimeError
    false
  end

  def unit(name, level, parent_id: nil, **options)
    unit_id = SecureRandom.uuid_v7
    @handler.create_unit(unit_id, name, level_id: id(level), parent_id:, effective_on: @today, **options)
    unit_id
  end

  def levels(names) = names.map { { level_id: id(it), name: it } }

  def id(name) = @level_ids[name] ||= SecureRandom.uuid_v7

  def as_tenant(&block)
    ActsAsTenant.with_tenant(@tenant, &block)
  end
end
