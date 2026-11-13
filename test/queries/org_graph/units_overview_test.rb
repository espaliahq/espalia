# frozen_string_literal: true

require "test_helper"

class OrgGraph::UnitsOverviewTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
  end

  def overview(selected_unit_id: nil)
    ActsAsTenant.with_tenant(@tenant) { OrgGraph::UnitsOverview.new(selected_unit_id:).tap(&:cards) }
  end

  def unit(key) = OrgUnit.find(@org[key])

  should "open the first root unit by default, and an unknown id falls back to it" do
    ActsAsTenant.with_tenant(@tenant) do
      assert_equal @org[:engineering], OrgGraph::UnitsOverview.new.selected.id
      assert_equal @org[:engineering], OrgGraph::UnitsOverview.new(selected_unit_id: SecureRandom.uuid_v7).selected.id
    end
  end

  should "count each person once across a unit and every unit beneath it" do
    ActsAsTenant.with_tenant(@tenant) do
      view = OrgGraph::UnitsOverview.new
      assert_equal 4, view.headcount(unit(:engineering))
      assert_equal 3, view.headcount(unit(:checkout))
      assert_equal 2, view.headcount(unit(:platform))
    end
  end

  should "open a unit with no members of its own to its sub-units, and a leaf to itself" do
    ActsAsTenant.with_tenant(@tenant) do
      assert_equal %w[Checkout Platform], OrgGraph::UnitsOverview.new.cards.map(&:name)
      assert_equal %w[Checkout Payments],
                   OrgGraph::UnitsOverview.new(selected_unit_id: @org[:checkout]).cards.map(&:name)
      assert_equal %w[Payments], OrgGraph::UnitsOverview.new(selected_unit_id: @org[:payments]).cards.map(&:name)
    end
  end

  should "name a member's other units" do
    ActsAsTenant.with_tenant(@tenant) do
      view = OrgGraph::UnitsOverview.new
      brook = view.members_of(unit(:platform)).find { |membership| membership.person == @org[:brook] }
      assert_equal %w[Checkout], view.other_units_of(brook).map(&:name)
    end
  end

  should "list only active people with no live unit as unplaced" do
    ActsAsTenant.with_tenant(@tenant) do
      assert_equal [ "Ezra Pell" ], OrgGraph::UnitsOverview.new.unplaced.map(&:name)
    end
  end

  should "leave out a retired unit and count its people as unplaced" do
    ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).retire_unit(@org[:payments], effective_on: "2026-03-01")
      view = OrgGraph::UnitsOverview.new

      assert_empty view.children_of(unit(:checkout))
      assert_equal 3, view.headcount(unit(:engineering))
      assert_equal [ "Dot Fennick", "Ezra Pell" ], view.unplaced.map(&:name)
    end
  end

  should "count and list only active members, as the tray does" do
    ActsAsTenant.with_tenant(@tenant) do
      @org[:dot].update!(status: "inactive")
      view = OrgGraph::UnitsOverview.new

      assert_equal 0, view.headcount(unit(:payments))
      assert_equal 3, view.headcount(unit(:engineering))
      assert_empty view.members_of(unit(:payments))
    end
  end

  should "treat a live unit whose parent is not live as a root, so it stays reachable" do
    ActsAsTenant.with_tenant(@tenant) do
      unit(:checkout).update_columns(retired_on: Date.new(2026, 3, 1))
      view = OrgGraph::UnitsOverview.new

      assert_equal %w[Engineering Payments], view.roots.map(&:name)
      assert_equal %w[Engineering Platform Payments], view.in_tree_order.map(&:name)
    end
  end

  should "ignore memberships of a unit created after the units were read" do
    ActsAsTenant.with_tenant(@tenant) do
      payments = @org[:payments]
      calls = 0
      first_read_misses_payments = lambda do
        calls += 1
        calls == 1 ? OrgUnit.where(retired_on: nil).where.not(id: payments) : OrgUnit.where(retired_on: nil)
      end

      view = OrgUnit.stub(:live, first_read_misses_payments) { OrgGraph::UnitsOverview.new }
      brook = view.members_of(unit(:platform)).find { |m| m.person_id == @org[:brook].id }

      assert_equal %w[Checkout], view.other_units_of(brook).map(&:name)
      assert_equal 3, view.headcount(unit(:engineering))
    end
  end

  should "hold nothing for a tenant with no structure" do
    ActsAsTenant.with_tenant(create(:tenant)) do
      view = OrgGraph::UnitsOverview.new
      assert_not view.any_units?
      assert_nil view.selected
      assert_empty view.cards
    end
  end
end
