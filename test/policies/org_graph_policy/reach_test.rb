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

    should "answer empty or false, and never raise, for nobody or someone who has left" do
      as_tenant { @owner.update!(status: "inactive") }
      payments = unit(@org[:payments])

      as_tenant do
        [ nil, @owner.reload ].each do |person|
          reach = OrgGraphPolicy::Reach.new(person)
          assert_not reach.covers?(payments)
          assert_not reach.covers?(nil)
          assert_empty reach.owned_unit_ids
        end
      end
    end

    should "never cross into another tenant, with or without a current tenant" do
      other_tenant = create(:tenant)
      other = build_org_graph(other_tenant)
      ActsAsTenant.with_tenant(other_tenant) do
        system = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        system.add_unit_owner(other[:checkout], other[:ezra].id, **ON)
        system.add_unit_owner(other[:engineering], other[:dot].id, **ON)
        other[:ezra].update_column(:manager_id, @manager.id)
        OrgUnitOwner.find_by!(unit_id: other[:engineering]).update_column(:person_id, @owner.id)
        OrgUnit.find(other[:payments]).update_column(:parent_id, @org[:payments])
      end
      foreign = ActsAsTenant.with_tenant(other_tenant) { OrgUnit.where(id: other.values_at(:engineering, :checkout, :payments)).to_a }

      [ -> { reach_of(@manager) }, -> { ActsAsTenant.without_tenant { OrgGraphPolicy::Reach.new(@manager.reload) } } ].each do |build|
        reach = build.call
        assert_equal [ @org[:payments] ].to_set, ActsAsTenant.without_tenant { reach.owned_unit_ids }
        foreign.each { |unit| assert_not ActsAsTenant.without_tenant { reach.covers?(unit) }, unit.name }
      end
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
                   "have such an owner below you in your reporting line, or are an Org Graph editor", error.message
    end

    should "refuse the owner of a unit its retyping, which is the structure's call" do
      error = assert_raises(OrgGraph::Authorization::Refused) do
        structure(as(@checkout_owner)).change_unit_kind(@org[:checkout], @lane, **ON)
      end

      assert_equal "You can change Checkout's type if you own the unit whose structure it sits in or a unit above that, " \
                   "have such an owner below you in your reporting line, or are an Org Graph editor", error.message
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
    assert_match "an owner of Payments Core or a unit above it, or anyone above them in the reporting line", error.message
    assert policy_for(as(@org[:ezra])).edit_unit?(unit(@org[:payments]))
  end

  should "check each command against the owners as they stand, though one handler runs it" do
    handler = structure(as(@manager))
    handler.rename_unit(@org[:payments], "Payments Core", **ON)
    as_tenant { system.remove_unit_owner(@org[:payments], @owner.id, **ON) }

    assert_raises(OrgGraph::Authorization::Refused) { handler.rename_unit(@org[:payments], "Payments", **ON) }
  end

  should "check a structure change again under the structure's lock, refusing an owner removed while it waited" do
    engineering = @org[:engineering]
    structure_changes.each_with_index do |(change, command), index|
      as_tenant { system.add_unit_owner(engineering, @engineering_owner.id, **ON) } unless index.zero?

      assert_refused_under_the_lock(change, command, as(@engineering_owner)) do
        system.remove_unit_owner(engineering, @engineering_owner.id, **ON)
      end
    end
  end

  should "check a structure change again under the structure's lock against the caller as it stands, not as it started" do
    lead = as(as_tenant { create(:person, tenant: @tenant).tap { @engineering_owner.update!(manager: it) } })
    {
      "a manager of the owner deactivated" => [ lead, ->(id) { Person.find(id).update!(status: "inactive") },
                                                ->(id) { Person.find(id).update!(status: "active") } ],
      "a manager of the owner unlinked from their account" => [ lead, ->(_) { TenantUser.find(lead.tenant_user.id).update!(person_id: nil) },
                                                                ->(id) { TenantUser.find(lead.tenant_user.id).update!(person_id: id) } ],
      "an editor's grant removed" => [ editor, ->(_) { TenantUser.find(editor.tenant_user.id).update!(org_graph_editor: false) },
                                       ->(_) { TenantUser.find(editor.tenant_user.id).update!(org_graph_editor: true) } ],
      "an admin demoted" => [ admin, ->(_) { TenantUser.find(admin.tenant_user.id).update!(role: :member) },
                              ->(_) { TenantUser.find(admin.tenant_user.id).update!(role: :admin) } ]
    }.each do |revocation, (context, revoke, restore)|
      structure_changes.each do |change, command|
        assert_refused_under_the_lock("#{change}, #{revocation}", command, context) { revoke.call(context.person.id) }
      ensure
        as_tenant { restore.call(context.person.id) }
      end
    end
  end

  should "check a move between structures and a unit's retyping again under the lock against the caller as it stands" do
    {
      "an editor's grant removed" => [ editor, ->(tenant_user) { tenant_user.update!(org_graph_editor: false) },
                                       ->(tenant_user) { tenant_user.update!(org_graph_editor: true) } ],
      "an admin demoted" => [ admin, ->(tenant_user) { tenant_user.update!(role: :member) },
                              ->(tenant_user) { tenant_user.update!(role: :admin) } ]
    }.each do |revocation, (context, revoke, restore)|
      cross_structure_changes.each do |change, command|
        assert_refused_under_the_lock("#{change}, #{revocation}", command, context) { revoke.call(TenantUser.find(context.tenant_user.id)) }
      ensure
        as_tenant { restore.call(TenantUser.find(context.tenant_user.id)) }
      end
    end
  end

  should "let the system change the organisation's types under the lock, with no person to read again" do
    level_id = SecureRandom.uuid_v7
    as_tenant { system.add_level(level_id, "Pod", **ON) }

    assert as_tenant { OrgTaxonomyLevel.exists?(id: level_id) }
  end

  should "give an owner, and the people above them, nothing through a unit once it retires" do
    ledger, newcomer = SecureRandom.uuid_v7, as_tenant { create(:person, tenant: @tenant) }
    later = { effective_on: "2026-03-01" }
    as_tenant do
      system.create_unit(ledger, "Ledger", level_id: @lane, parent_id: @org[:checkout], **ON)
      system.add_unit_owner(ledger, @owner.id, **ON)
      system.retire_unit(ledger, **later)
    end

    [ @owner, @manager ].each do |person|
      assert_equal [ @org[:payments] ].to_set, reach_of(person).owned_unit_ids, "Payments, still live, stays in reach"
      context = as(person)
      assert_not as_tenant { policy_for(context).edit_unit?(unit(ledger)) }
      assert_not policy_for(context).show_units?
      handler = structure(context)
      {
        "a rename" => -> { handler.rename_unit(ledger, "Ledger 2", **later) },
        "a retirement" => -> { handler.retire_unit(ledger, **later) },
        "an owner added" => -> { handler.add_unit_owner(ledger, newcomer.id, **later) },
        "an owner removed" => -> { handler.remove_unit_owner(ledger, @owner.id, **later) },
        "a unit beneath it" => -> { handler.create_unit(SecureRandom.uuid_v7, "Pod", level_id: @lane, parent_id: ledger, **later) },
        "a structure declared" => -> { handler.declare_structure(ledger, levels: [], conversion: {}, **later) },
        "a type added to it" => -> { handler.add_level(SecureRandom.uuid_v7, "Pod", structure_unit_id: ledger, **later) },
        "a member placed" => -> { people(context).set_membership(newcomer.id, ledger, provider: "espalia", allocation: 1, **later) }
      }.each do |write, command|
        assert_raises(OrgGraph::Authorization::Refused, "#{write} by #{person.id}") { command.call }
      end
    end
    error = assert_raises(RuntimeError) { structure(as(admin)).move_unit(@org[:payments], ledger, **later) }
    assert_equal "Parent unit is retired", error.message, "so no live unit sits beneath a retired one"
  end

  should "A person who is an owner but inactive has no reach" do
    as_tenant { @owner.update!(status: "inactive") }
    context = as(@owner)

    assert_empty reach_of(@owner).owned_unit_ids
    assert_equal({ unit: false, billing: false, structure: false, org: false, kind: false, place: false, move: false }, rights_of(context))
    assert_raises(OrgGraph::Authorization::Refused) { structure(context).rename_unit(@org[:payments], "Payments Core", **ON) }
  end

  should "build one reach for a check, however many units it names, and one for a screen's change-back checks" do
    lanes = as_tenant do
      Array.new(12) { SecureRandom.uuid_v7.tap { system.create_unit(it, "Lane #{it.last(4)}", level_id: @lane, parent_id: @org[:payments], **ON) } }
    end
    handler = structure(as(@manager))
    handler.rename_unit(@org[:payments], "Payments Core", **ON)
    handler.rename_unit(lanes.first, "First lane", **ON)
    entries = as_tenant { OrgUnitActivity.where(unit_id: [ @org[:payments], lanes.first ], event_type: "UnitRenamed").to_a }

    assert_equal 1, reaches_built {
      error = assert_raises(OrgGraph::Authorization::Refused) do
        handler.record_succession(SecureRandom.uuid_v7, predecessor_ids: lanes, successor_ids: [ @org[:checkout] ], **ON)
      end
      assert_match "Checkout", error.message
    }

    change_back = StructureHandler.new(@tenant, OrgGraph::ChangeBackHandler.new(actor: as(@manager)))
    assert_equal 1, reaches_built { entries.each { assert_nil change_back.refusal(it) } }
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

  # Takes a right away after the handler's first check and before it takes the structure's lock.
  RevokingRepository = Struct.new(:repository, :revoke) do
    def with_structure(...)
      revoke&.call
      self.revoke = nil
      repository.with_structure(...)
    end

    def method_missing(name, ...) = repository.public_send(name, ...)

    def respond_to_missing?(name, include_private = false) = repository.respond_to?(name, include_private) || super
  end

  def structure_changes
    engineering = @org[:engineering]
    {
      "a new type" => ->(handler) { handler.add_level(SecureRandom.uuid_v7, "Pod", structure_unit_id: engineering, **ON) },
      "a type's parents" => ->(handler) { handler.set_kind_parents(@lane, parent_ids: [ @group ], top: false, structure_unit_id: engineering, **ON) },
      "a type removed" => ->(handler) { handler.remove_level(@lane, structure_unit_id: engineering, **ON) },
      "a withdrawal" => ->(handler) { handler.withdraw_structure(engineering, **ON) },
      "a declaration" => ->(handler) { handler.declare_structure(@org[:checkout], levels: [], conversion: {}, **ON) },
      "a declaration changed back" => ->(handler) { handler.change_declaration_back(engineering, kinds: {}, changed_back_id: SecureRandom.uuid_v7, **ON) },
      "a withdrawal changed back" => lambda { |handler|
        handler.change_withdrawal_back(engineering, levels: [], kinds: {}, changed_back_id: SecureRandom.uuid_v7, **ON)
      }
    }
  end

  def cross_structure_changes
    {
      "a move between structures" => ->(handler) { handler.move_unit(@org[:payments], nil, conversion: { @lane => @org[:squad] }, **ON) },
      "a move between structures changed back" => lambda { |handler|
        handler.change_move_back(@org[:payments], nil, kinds: {}, changed_back_id: SecureRandom.uuid_v7, **ON)
      },
      "a unit retyped" => ->(handler) { handler.change_unit_kind(@org[:checkout], @lane, **ON) }
    }
  end

  # Runs the command as the caller, taking the right away between its first
  # check and the lock, and asserts it is refused and writes nothing.
  def assert_refused_under_the_lock(change, command, context)
    events_after_revoke = nil
    revoke = lambda do
      yield
      events_after_revoke = Rails.configuration.event_store.read.count
    end
    handler = OrgGraph::StructureCommandHandler.new(actor: context,
                                                    repository: RevokingRepository.new(OrgGraph::Repository.new, revoke))

    assert_raises(OrgGraph::Authorization::Refused, change) { StructureHandler.new(@tenant, handler).then { command.call(it) } }
    assert_equal events_after_revoke, Rails.configuration.event_store.read.count, change
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

  def reaches_built
    built = 0
    OrgGraphPolicy::Reach.alias_method(:__counted_initialize, :initialize)
    OrgGraphPolicy::Reach.define_method(:initialize) { |person| built += 1; __counted_initialize(person) }
    yield
    built
  ensure
    OrgGraphPolicy::Reach.alias_method(:initialize, :__counted_initialize)
    OrgGraphPolicy::Reach.remove_method(:__counted_initialize)
  end

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
