# frozen_string_literal: true

require "test_helper"

# Each row of the worked example on #537, as the policy answers it.
class OrgGraphPolicy::LineAboveOwnerTest < ActiveSupport::TestCase
  include OrgGraphRightsExample

  setup { build_rights_example }

  def policy(person, **) = OrgGraphPolicy.new(context_for(person, **), :org_graph)

  should "let anyone above an owner change the owner's unit, the structure it declares and everything beneath it" do
    [ @sam, @lee ].each do |manager|
      rights = policy(manager)
      assert rights.edit_unit?(unit(@payments)), "#{manager.name} is above Priya"
      assert rights.edit_structure_of?(unit(@payments))
      assert rights.place?(as_tenant { create(:person, tenant: @tenant) }, unit(@payments)), "a contractor who reports to nobody #{manager.name} manages"
      assert_not rights.edit_unit?(unit(@commerce))
      assert_not rights.edit_unit?(unit(@billing))
    end
  end

  should "not reach a structure declared above the units the line covers" do
    sam = policy(@sam)

    assert_not sam.edit_structure_of?(unit(@engineering))
    assert_not sam.edit_structure_of?(nil)
    assert_not sam.change_unit_kind?(unit(@payments)), "Payments' type belongs to Engineering's structure"
  end

  should "leave retyping to whoever holds the structure the unit sits in" do
    assert_not policy(@dana).change_unit_kind?(unit(@commerce)), "Dana's reach starts at Commerce"
    assert policy(@dana).edit_unit?(unit(@commerce))

    pod_kind, pod = Array.new(2) { SecureRandom.uuid_v7 }
    as_tenant do
      structure_handler(context_for(@sam)).declare_structure(@payments, levels: [ { level_id: pod_kind, name: "Pod" } ], conversion: {},
                                                                        effective_on: ON)
      @system.create_unit(pod, "Pod A", level_id: pod_kind, parent_id: @payments, effective_on: ON)
    end
    assert policy(@sam).change_unit_kind?(unit(pod)), "Pod A's type belongs to Payments' structure, which Sam holds"
  end

  should "give an Org Graph editor every structure, the organisation's included" do
    omar = OrgGraphPolicy.new(omar_context, :org_graph)

    assert [ nil, unit(@engineering), unit(@payments) ].all? { omar.edit_structure_of?(it) }
    assert omar.edit_taxonomy?
    assert omar.change_unit_kind?(unit(@commerce))
    assert omar.move_unit?(unit(@payments), nil)
  end

  should "move a member only where the caller covers both units, or manages the member" do
    assert_not policy(@sam).move_membership?(@kim, unit(@payments), unit(@billing)), "Sam covers Payments, not Billing, and Kim reports to Dana"
    assert policy(@dana).move_membership?(@kim, unit(@payments), unit(@billing))
  end

  should "hold no right for a member who owns nothing and manages no one" do
    kim = policy(@kim)

    assert_not kim.edit_unit?(unit(@payments))
    assert_not kim.edit_structure_of?(unit(@payments))
    assert_not kim.place?(@dana, unit(@payments))
  end

  should "drop the line's rights at the next request once the owner leaves" do
    as_tenant { @priya.update!(status: "inactive") }

    assert_not policy(@sam).edit_unit?(unit(@payments))
    assert_not policy(@lee).edit_unit?(unit(@payments))
  end

  should "keep the line through a manager in between who has left" do
    as_tenant { @sam.update!(status: "inactive") }

    assert policy(@lee).edit_unit?(unit(@payments))
    assert_not policy(@sam).edit_unit?(unit(@payments)), "only a caller still working here holds rights"
  end

  should "count only the line as it stands, at any depth" do
    as_tenant { @priya.update!(manager: @dana) }

    assert_not policy(@lee).edit_unit?(unit(@payments))
    assert_not policy(@sam).edit_unit?(unit(@payments))
  end

  context "its reach" do
    should "end the walk when the reporting line loops" do
      as_tenant { @lee.update!(manager: @priya) }

      assert_equal [ @payments ].to_set, as_tenant { OrgGraphPolicy::Reach.new(@lee).owned_unit_ids }
      assert as_tenant { OrgGraphPolicy::Reach.new(@priya).covers?(unit(@payments)) }
    end

    should "end the walk when the units' parents loop" do
      reach = OrgGraphPolicy::Reach.new(@sam)
      a, b = Array.new(2) { SecureRandom.uuid_v7 }
      looped = [ OrgUnit.new(id: a, parent_id: b), OrgUnit.new(id: b, parent_id: a) ]

      assert_equal [ a, b ], reach.index(looped).lineage(looped.first).map(&:id)
    end

    should "reach nothing for nobody, or for someone who has left" do
      as_tenant { @priya.update!(status: "inactive") }

      assert_empty OrgGraphPolicy::Reach.new(nil).owned_unit_ids
      assert_empty as_tenant { OrgGraphPolicy::Reach.new(@priya).owned_unit_ids }
      assert_not OrgGraphPolicy::Reach.new(nil).covers?(unit(@payments))
    end

    should "read the rights for a whole tree in a fixed number of queries, whatever its size" do
      small = rights_queries_for_tree(5)
      large = rights_queries_for_tree(200)

      assert_equal small, large
    end
  end

  private

  # Grows a chain of units beneath Billing to the size given, then counts the
  # queries one policy makes to answer edit_unit? for every unit in the tree.
  # The rows are written straight to the read model: the count is about the
  # policy's reads, not the commands that would write them.
  def rights_queries_for_tree(size)
    as_tenant do
      parent = @billing
      rows = Array.new(size - OrgUnit.count) do |index|
        { id: SecureRandom.uuid_v7, tenant_id: @tenant.id, name: "Unit #{size}-#{index}", level_id: @team, provider: "espalia",
          name_effective_on: ON, parent_effective_on: ON, created_on: ON }
      end
      rows.each { |row| row[:parent_id] = parent; parent = row[:id] }
      OrgUnit.insert_all!(rows) if rows.any?
      units = OrgGraph::UnitsOverview.new.in_tree_order
      rights = OrgGraphPolicy.new(context_for(@lee), :org_graph)
      rights.reach.index(units)
      count_queries { units.each { rights.edit_unit?(it) } }
    end
  end

  def count_queries
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end
end
