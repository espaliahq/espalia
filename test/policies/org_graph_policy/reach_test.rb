# frozen_string_literal: true

require "test_helper"

# Rights over a structure (#537): an owner, and anyone an owner reports to,
# may change the unit, everything beneath it and the structure in force there.
#
#   Engineering (department), declaring Group and Lane
#     Checkout (Group), owned by checkout_owner
#       Payments (Lane), owned by owner, who reports to manager, who reports to skip
#       Billing (Lane), owned by Faye Lumen, who has left
#   Product (team), in the organisation's structure
class OrgGraphPolicy::ReachTest < ActiveSupport::TestCase
  include OrgGraphFixture

  ON = { effective_on: "2026-02-01" }.freeze

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    @group, @lane, @billing, @product = Array.new(4) { SecureRandom.uuid_v7 }

    as_tenant do
      @skip = create(:person, tenant: @tenant)
      @manager = create(:person, tenant: @tenant, manager: @skip)
      @owner = create(:person, tenant: @tenant, manager: @manager)
      @checkout_owner = create(:person, tenant: @tenant)
      @engineering_owner = create(:person, tenant: @tenant)
      @leavers_manager = create(:person, tenant: @tenant)
      @org[:faye].update!(manager: @leavers_manager)
      @org[:dot].update!(manager: @checkout_owner)

      system.create_unit(@billing, "Billing", level_id: @org[:squad], parent_id: @org[:checkout], **ON)
      system.create_unit(@product, "Product", level_id: @org[:team], **ON)
      { payments: @owner, checkout: @checkout_owner, engineering: @engineering_owner }.each do |unit, person|
        system.add_unit_owner(@org[unit], person.id, **ON)
      end
      system.add_unit_owner(@billing, @org[:faye].id, **ON)
      structure(as(admin)).declare_structure(
        @org[:engineering], levels: [ { level_id: @group, name: "Group", top: true },
                                      { level_id: @lane, name: "Lane", parent_level_ids: [ @group, @lane ], top: false } ],
                            conversion: { @org[:team] => @group, @org[:squad] => @lane }, **ON
      )
    end
  end

  context "a reach" do
    should "cover the units owned in the caller's subtree and everything beneath them, and nothing above" do
      [ @owner, @manager, @skip ].each do |person|
        reach = reach_of(person)
        assert reach.covers?(unit(@org[:payments]))
        assert_not reach.covers?(unit(@org[:checkout]))
        assert_not reach.covers?(nil)
      end
      assert reach_of(@checkout_owner).covers?(unit(@billing))
      assert_empty reach_of(@org[:ezra]).owned_unit_ids
    end

    should "stop at a cycle in the reporting line" do
      as_tenant { @skip.update_column(:manager_id, @owner.id) }

      assert_equal [ @org[:payments] ].to_set, reach_of(@manager).owned_unit_ids
    end

    should "drop an owner who has left, and keep the line through a manager in between who has left" do
      as_tenant { @manager.update!(status: "inactive") }
      assert reach_of(@skip).covers?(unit(@org[:payments]))

      assert_not reach_of(@leavers_manager).covers?(unit(@billing))
      assert reach_of(@checkout_owner).covers?(unit(@billing)), "the unit above still covers it"
    end

    should "be empty for a person who is an owner but inactive" do
      as_tenant { @owner.update!(status: "inactive") }

      assert_empty reach_of(@owner).owned_unit_ids
      assert_not policy_for(as(@owner)).edit_unit?(unit(@org[:payments]))
    end
  end

  context "the rights matrix" do
    should "give each caller the rights their place in the line holds, and nothing else" do
      owner_rights = { unit: true, billing: false, structure: false, org: false, kind: false, place: true, move: false }
      none = owner_rights.transform_values { false }
      expected = {
        "admin" => [ admin, owner_rights.transform_values { true } ],
        "editor" => [ editor, owner_rights.transform_values { true } ],
        "owner" => [ @owner, owner_rights ],
        "owner of the unit above" => [ @checkout_owner, owner_rights.merge(billing: true, move: true) ],
        "owner of the unit declaring the structure" => [ @engineering_owner, owner_rights.transform_values { true }.merge(org: false) ],
        "owner's manager" => [ @manager, owner_rights ],
        "skip-level manager" => [ @skip, owner_rights ],
        "unrelated member" => [ @org[:ezra], none ],
        "owner who has left" => [ @org[:faye], none ],
        "manager of an owner who has left" => [ @leavers_manager, none ]
      }

      expected.each do |caller, (who, rights)|
        assert_equal rights, rights_of(who.is_a?(AuthorizationContext) ? who : as(who)), caller
      end
    end

    should "let the system change units but no structure" do
      structure(OrgGraph::Authorization::SYSTEM).rename_unit(@org[:payments], "Payments Core", **ON)

      error = assert_raises(OrgGraph::Authorization::Refused) do
        structure(OrgGraph::Authorization::SYSTEM).add_level(SecureRandom.uuid_v7, "Pod", structure_unit_id: @org[:engineering], **ON)
      end
      assert_equal "The system cannot change a structure", error.message
    end
  end

  context "the worked example" do
    should "let the owner's skip-level manager rename the owner's unit" do
      structure(as(@skip)).rename_unit(@org[:payments], "Payments Core", **ON)

      assert_equal "Payments Core", unit(@org[:payments]).name
    end

    should "refuse the owner's manager a type in the structure above the owner's unit" do
      error = assert_raises(OrgGraph::Authorization::Refused) do
        structure(as(@manager)).add_level(SecureRandom.uuid_v7, "Pod", structure_unit_id: @org[:engineering], **ON)
      end

      assert_equal "You can change Engineering's structure if you own Engineering or a unit above it, " \
                   "report to someone who does, or are an Org Graph editor", error.message
    end

    should "refuse the owner of a unit its retyping, which is the structure's call" do
      error = assert_raises(OrgGraph::Authorization::Refused) do
        structure(as(@checkout_owner)).change_unit_kind(@org[:checkout], @lane, **ON)
      end

      assert_equal "You can change Checkout's type if you own the unit whose structure it sits in or a unit above that, " \
                   "report to someone who does, or are an Org Graph editor", error.message
      assert_equal @group, unit(@org[:checkout]).level_id
    end

    should "let an editor add a type to a unit's structure and move a unit between structures" do
      structure(as(editor)).add_level(SecureRandom.uuid_v7, "Pod", structure_unit_id: @org[:engineering], **ON)
      structure(as(editor)).move_unit(@org[:payments], nil, conversion: { @lane => @org[:squad] }, **ON)

      assert_nil unit(@org[:payments]).parent_id
    end

    should "refuse the owner's manager a move to the top, naming no structure" do
      error = assert_raises(OrgGraph::Authorization::Refused) do
        structure(as(@manager)).move_unit(@org[:payments], nil, conversion: { @lane => @org[:squad] }, **ON)
      end

      assert_equal "Only a tenant admin or an Org Graph editor can place a unit at the root", error.message
    end

    should "refuse the owner's manager a membership move to a unit outside their reach, for someone they don't manage" do
      error = assert_raises(OrgGraph::Authorization::Refused) do
        people(as(@manager)).move_membership(@org[:dot].id, @org[:payments], @billing, **ON)
      end

      assert_equal "Only a tenant admin, an Org Graph editor, Dot Fennick's manager chain or someone with rights over " \
                   "both Payments and Billing can move this membership", error.message
    end

    should "keep the Units view from someone who holds no right" do
      assert_not policy_for(as(@org[:dot])).show_units?
    end
  end

  context "a move between structures" do
    setup { as_tenant { system.add_unit_owner(@product, @engineering_owner.id, **ON) } }

    should "need the right to change both, naming neither" do
      refusal = "You need the right to change both structures to move a unit between them"
      as_tenant { system.add_unit_owner(@product, @owner.id, **ON) }
      moves = {
        "neither structure" => -> { structure(as(@owner)).move_unit(@org[:payments], @product, conversion: { @lane => @org[:squad] }, **ON) },
        "the source only" => -> { structure(as(@engineering_owner)).move_unit(@org[:payments], @product, conversion: { @lane => @org[:squad] }, **ON) },
        "the destination only" => -> { structure(as(@engineering_owner)).move_unit(@product, @org[:checkout], conversion: { @org[:team] => @lane }, **ON) }
      }

      moves.each do |held, move|
        error = assert_raises(OrgGraph::Authorization::Refused, held) { move.call }
        assert_equal refusal, error.message, held
      end
      assert_equal @org[:checkout], unit(@org[:payments]).parent_id
    end
  end

  should "A manager whose report owns a unit loses the right in the same request cycle when the report's manager changes, " \
         "with no stale memo across requests" do
    first_request = as(@manager)
    assert policy_for(first_request).edit_unit?(unit(@org[:payments]))
    structure(first_request).rename_unit(@org[:payments], "Payments Core", **ON)

    as_tenant { @owner.update!(manager: @org[:ezra]) }

    next_request = as(@manager)
    assert_not policy_for(next_request).edit_unit?(unit(@org[:payments]))
    error = assert_raises(OrgGraph::Authorization::Refused) { structure(next_request).rename_unit(@org[:payments], "Payments", **ON) }
    assert_match "an owner of Payments Core or a unit above it, or someone they report to", error.message
    assert policy_for(as(@org[:ezra])).edit_unit?(unit(@org[:payments]))
  end

  should "check each command against the owners as they stand, though one handler runs it" do
    handler = structure(as(@manager))
    handler.rename_unit(@org[:payments], "Payments Core", **ON)
    as_tenant { system.remove_unit_owner(@org[:payments], @owner.id, **ON) }

    assert_raises(OrgGraph::Authorization::Refused) { handler.rename_unit(@org[:payments], "Payments", **ON) }
  end

  should "A person who is an owner but inactive has no reach" do
    as_tenant { @owner.update!(status: "inactive") }
    context = as(@owner)

    assert_empty reach_of(@owner).owned_unit_ids
    assert_equal({ unit: false, billing: false, structure: false, org: false, kind: false, place: false, move: false }, rights_of(context))
    assert_raises(OrgGraph::Authorization::Refused) { structure(context).rename_unit(@org[:payments], "Payments Core", **ON) }
  end

  should "read rights over a large tree in as many queries as over a small one" do
    small = queries_for_rights_over(4)
    large = queries_for_rights_over(200)

    assert_equal small, large
  end

  private

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def system = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)

  def structure(actor) = StructureHandler.new(@tenant, OrgGraph::StructureCommandHandler.new(actor:))

  def people(actor) = StructureHandler.new(@tenant, OrgGraph::CommandHandler.new(actor:))

  # Runs each command inside the tenant, as a request would.
  StructureHandler = Struct.new(:tenant, :handler) do
    def method_missing(name, ...) = ActsAsTenant.with_tenant(tenant) { handler.public_send(name, ...) }

    def respond_to_missing?(name, include_private = false) = handler.respond_to?(name, include_private) || super
  end

  def unit(id) = as_tenant { OrgUnit.find(id) }

  def admin = @admin ||= as(as_tenant { create(:person, tenant: @tenant) }, role: :admin)

  def editor = @editor ||= as(as_tenant { create(:person, tenant: @tenant) }, org_graph_editor: true)

  def as(person, role: :member, org_graph_editor: false)
    return person if person.is_a?(AuthorizationContext)

    as_tenant do
      person.reload
      tenant_user = TenantUser.find_by(tenant: @tenant, person:) ||
                    create(:tenant_user, tenant: @tenant, person:, role:, org_graph_editor:)
      AuthorizationContext.new(user: tenant_user.user, tenant_user:, person:)
    end
  end

  def policy_for(context) = OrgGraphPolicy.new(context, :org_graph)

  def reach_of(person) = as_tenant { OrgGraphPolicy::Reach.new(person.reload) }

  def rights_of(context)
    as_tenant do
      policy = policy_for(context)
      payments, billing, engineering = [ @org[:payments], @billing, @org[:engineering] ].map { OrgUnit.find(it) }
      dot = @org[:dot].reload
      { unit: policy.edit_unit?(payments), billing: policy.edit_unit?(billing),
        structure: policy.edit_structure_of?(engineering), org: policy.edit_structure_of?(nil),
        kind: policy.change_unit_kind?(engineering), place: policy.place?(dot, payments),
        move: policy.move_membership?(dot, payments, billing) }
    end
  end

  def queries_for_rights_over(count)
    parent = @org[:payments]
    ids = as_tenant do
      Array.new(count) do |index|
        SecureRandom.uuid_v7.tap do |id|
          system.create_unit(id, "Lane #{count}-#{index}", level_id: @lane, parent_id: index.even? ? parent : @org[:payments], **ON)
          parent = id
        end
      end
    end
    as_tenant do
      units = OrgUnit.where(id: ids).to_a
      policy = policy_for(as(@manager))
      queries = 0
      counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        assert(units.all? { policy.edit_unit?(it) })
      end
      queries
    end
  end
end
