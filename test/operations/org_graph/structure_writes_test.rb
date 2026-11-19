# frozen_string_literal: true

require "test_helper"
require_relative "../../support/rebuild_lock"

# Declaring and withdrawing a unit's own structure, and changing its types,
# through the operations MCP and the web share (#494).
class Operations::OrgGraph::StructureWritesTest < ActiveSupport::TestCase
  include OrgGraphFixture
  include RebuildLock

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @editor = create(:tenant_user, tenant: @tenant, role: :member, org_graph_editor: true,
                                     person: create(:person, tenant: @tenant))
    end
  end

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person)
      operation.call(context: context, params: params)
    end
  end

  def declare(**params)
    call(Operations::OrgGraph::DeclareStructure, unit_id: @org[:checkout],
                                                 levels: [ { name: "Stream" }, { name: "Lane", parent_names: [ "stream" ], top: false } ],
                                                 conversion: { @org[:squad] => "Stream" }, **params)
  end

  def level_of(unit) = ActsAsTenant.with_tenant(@tenant) { OrgUnit.find(@org[unit]).level_id }

  def move_in(as: @admin, conversion: { @org[:team] => @stream })
    call(Operations::OrgGraph::MoveUnit, as:, unit_id: @org[:platform], parent_id: @org[:checkout], conversion:)
  end

  def members_of(unit) = ActsAsTenant.with_tenant(@tenant) { OrgMembership.where(unit_id: @org[unit]).pluck(:person_id, :allocation).sort }

  context "DeclareStructure" do
    should "give a unit its own types, minting their ids and converting the units beneath it" do
      result = declare

      stream, lane = result[:levels].pluck(:level_id)
      assert_equal [ "Checkout", %w[Stream Lane], { @org[:squad] => stream } ],
                   [ result[:name], result[:levels].pluck(:name), result[:conversion] ]
      assert_equal [ [ stream ], false ], result[:levels].last.values_at(:parent_ids, :top)
      assert_equal [ stream, @org[:team] ], [ level_of(:payments), level_of(:checkout) ]
      assert_not_includes [ @org[:department], @org[:team], @org[:squad] ], lane
      event = Rails.configuration.event_store.read.of_type(OrgGraph::Events::TaxonomyDefined).last
      assert_equal [ @org[:checkout], @admin.person.id ], event.data.values_at(:structure_unit_id, :defined_by_id)
    end

    should "refuse names it can't place, a duplicate name, and a conversion that leaves a type out" do
      error = assert_raises(Operations::Base::ParameterError) { declare(conversion: { @org[:squad] => "Pod" }) }
      assert_equal "The conversion names a type, \"Pod\", that isn't in the structure", error.message

      error = assert_raises(Operations::Base::ParameterError) { declare(levels: [ { name: "Stream" }, { name: "stream" } ]) }
      assert_equal "Each unit type needs its own name", error.message

      error = assert_raises(Operations::Base::ParameterError) { declare(levels: [ { name: "Stream" } ], conversion: {}) }
      assert_equal "Say what Squad units become", error.message
      assert_equal @org[:squad], level_of(:payments)
    end

    should "refuse a malformed unit type as a parameter error, naming an unknown key" do
      { [ "Stream" ] => "Each unit type must be an object",
        [ { name: "Stream", parent_names: "Lane" } ] => "parent_names must be a list of type names",
        [ { name: "Stream", parent_name: [ "Lane" ] } ] => "A unit type can't take \"parent_name\"" }.each do |levels, message|
        error = assert_raises(Operations::Base::ParameterError) { declare(levels:) }
        assert_equal message, error.message
      end
      assert_equal @org[:squad], level_of(:payments)
    end

    should "change back a structure given to a unit with nothing beneath it, from its activity" do
      call(Operations::OrgGraph::DeclareStructure, unit_id: @org[:payments], levels: [ { name: "Stream" } ], conversion: {})

      ActsAsTenant.with_tenant(@tenant) do
        context = AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person)
        item = OrgGraph::ActivityFeed.new(unit: OrgUnit.find(@org[:payments]), actor: context).items.first

        assert_equal [ true, nil ], [ item.whole_cause?, item.refusal ]
        call(Operations::OrgGraph::ChangeBackGroup, cause_id: item.group.cause_id)
        assert_empty OrgGraph::Repository.new.load_structure.declared_structures.fetch(@org[:payments], nil)&.kinds.to_a
      end
    end

    should "name the types a declaration gave once it is changed back, in the feed of a unit it retyped" do
      declare
      ActsAsTenant.with_tenant(@tenant) do
        call(Operations::OrgGraph::ChangeBackGroup, cause_id: OrgUnitActivity.where(subject: "structure").order(:position).last.cause_id)
        context = AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person)
        parts = OrgGraph::ActivityFeed.new(unit: OrgUnit.find(@org[:payments]), actor: context).items.flat_map(&:parts)
        descriptions = parts.select { it.entry.subject == "level" }.map(&:description)

        assert_includes descriptions, "Changed its type from Squad to Stream"
        assert_includes descriptions, "Changed its type from Stream to Squad"
      end
    end

    should "leave a unit's structure to a tenant admin" do
      error = assert_raises(Pundit::NotAuthorizedError) { declare(as: @editor) }

      assert_equal "Only a tenant admin can change Checkout's structure", error.message
      assert_equal @org[:squad], level_of(:payments)
    end
  end

  should "move a tenant-wide type into one unit's structure, then retire it tenant-wide (the worked example)" do
    today = ActsAsTenant.with_tenant(@tenant) { Tenant.today }
    added_on, declared_on = (today - 10).iso8601, today - 5
    stream = call(Operations::OrgGraph::AddLevel, name: "Stream", parent_ids: [ @org[:team] ], top: false, effective_on: added_on)[:level_id]
    call(Operations::OrgGraph::SetKindParents, level_id: @org[:squad], parent_ids: [ @org[:team], stream ], top: false, effective_on: added_on)
    call(Operations::OrgGraph::ChangeUnitKind, unit_id: @org[:payments], level_id: stream, effective_on: added_on)
    declare(levels: [ { name: "Stream", copied_from_level_id: stream } ], conversion: { stream => "Stream" },
            copied_from: "top", effective_on: declared_on.iso8601)

    error = assert_raises(Operations::Base::ParameterError) do
      call(Operations::OrgGraph::RemoveLevel, level_id: stream, effective_on: (declared_on - 1).iso8601)
    end
    assert_equal "Payments was a Stream until #{(declared_on - 1).iso8601}, so date its removal after then", error.message
    call(Operations::OrgGraph::RemoveLevel, level_id: stream, effective_on: declared_on.iso8601)

    before, after = [ declared_on - 1, declared_on ].map { call(Operations::OrgGraph::AsOf, date: it.iso8601) }
    assert_equal [ %w[Department Team Squad Stream], [] ], [ before[:kinds].pluck(:name), before[:structures] ]
    assert_equal [ %w[Department Team Squad], [ [ @org[:checkout], %w[Stream] ] ] ],
                 [ after[:kinds].pluck(:name), after[:structures].map { [ it[:unit_id], it[:kinds].pluck(:name) ] } ]
    copy = after[:structures].sole[:kinds].sole[:id]
    assert_equal [ stream, copy ], [ before, after ].map { |read| read[:units].find { it[:id] == @org[:payments] }[:level_id] }
    assert_equal [ copy, %w[Department Team Squad] ],
                 [ level_of(:payments), ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.top_structure.pluck(:name) } ]
  end

  context "with a structure declared" do
    setup { @stream, @lane = declare[:levels].pluck(:level_id) }

    should "add, rule and remove its types without touching the top structure" do
      pod = call(Operations::OrgGraph::AddLevel, name: "Pod", parent_ids: [ @lane ], structure_unit_id: @org[:checkout])
      assert_equal [ @org[:checkout], %w[Stream Lane Pod] ], [ pod[:structure_unit_id], pod[:levels].pluck(:name) ]

      ruled = call(Operations::OrgGraph::SetKindParents, level_id: pod[:level_id], parent_ids: [ @stream ], top: false,
                                                         structure_unit_id: @org[:checkout])
      assert_equal [ @stream ], ruled[:parent_ids]

      removed = call(Operations::OrgGraph::RemoveLevel, level_id: pod[:level_id], structure_unit_id: @org[:checkout])
      assert_equal %w[Stream Lane], removed[:levels].pluck(:name)
      assert_equal %w[Department Team Squad], ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.top_structure.pluck(:name) }
    end

    should "leave its types to a tenant admin" do
      error = assert_raises(Pundit::NotAuthorizedError) do
        call(Operations::OrgGraph::AddLevel, as: @editor, name: "Pod", structure_unit_id: @org[:checkout])
      end
      assert_equal "Only a tenant admin can change Checkout's structure", error.message
    end

    should "withdraw it, converting the units beneath it back" do
      result = call(Operations::OrgGraph::WithdrawStructure, unit_id: @org[:checkout], conversion: { @stream => @org[:squad] })

      assert_equal({ @stream => @org[:squad] }, result[:conversion])
      assert_equal @org[:squad], level_of(:payments)
      assert_empty ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.in_structure(@org[:checkout]) }
    end

    should "refuse a withdrawal that leaves a held type out" do
      error = assert_raises(Operations::Base::ParameterError) do
        call(Operations::OrgGraph::WithdrawStructure, unit_id: @org[:checkout], conversion: {})
      end
      assert_equal "Say what Stream units become", error.message
    end
  end

  context "reading a declared structure" do
    setup { @stream, @lane = declare[:levels].pluck(:level_id) }

    should "give each unit the structure in force above it in the Units read" do
      result = call(Operations::OrgGraph::Units)

      units = result[:units].index_by { it[:id] }
      assert_equal [ nil, @org[:checkout] ], units.values_at(@org[:checkout], @org[:payments]).pluck(:structure_unit_id)
      assert_equal [ [ @org[:checkout], "Checkout", %w[Stream Lane] ] ],
                   result[:structures].map { [ it[:unit_id], it[:name], it[:levels].pluck(:name) ] }
      assert_equal %w[Department Team Squad], result[:levels].pluck(:name)
    end

    should "list a structure's types with their units and whether each can go, in Sources" do
      structure = call(Operations::OrgGraph::Sources)[:structures].sole

      assert_equal [ @org[:checkout], "Checkout" ], structure.values_at(:unit_id, :name)
      assert_equal [ [ "Stream", 1, false ], [ "Lane", 0, true ] ], structure[:levels].map { it.values_at(:name, :live_units, :removable) }
      assert_equal [ false, false ], call(Operations::OrgGraph::Sources, as: @editor)[:structures].sole[:levels].pluck(:removable)
    end

    should "read the structure in force on a date, even narrowed to a unit beneath it" do
      day = ActsAsTenant.with_tenant(@tenant) { Tenant.today.iso8601 }
      [ {}, { unit_id: @org[:payments] } ].each do |narrowed|
        result = call(Operations::OrgGraph::AsOf, date: day, **narrowed)
        assert_equal [ [ @org[:checkout], "Checkout", %w[Stream Lane] ] ],
                     result[:structures].map { [ it[:unit_id], it[:name], it[:kinds].pluck(:name) ] }
      end
      assert_empty call(Operations::OrgGraph::AsOf, date: day, unit_id: @org[:platform])[:structures]
    end

    should "read the structure a declaring unit sits in, narrowed to that unit" do
      call(Operations::OrgGraph::DeclareStructure, unit_id: @org[:payments], levels: [ { name: "Pod" } ], conversion: {})
      day = ActsAsTenant.with_tenant(@tenant) { Tenant.today.iso8601 }

      result = call(Operations::OrgGraph::AsOf, date: day, unit_id: @org[:payments])

      assert_equal({ @org[:checkout] => %w[Stream Lane], @org[:payments] => %w[Pod] },
                   result[:structures].to_h { [ it[:unit_id], it[:kinds].pluck(:name) ] })
    end

    should "offer a unit only the types and places of the structure in force where it sits" do
      ActsAsTenant.with_tenant(@tenant) do
        context = AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person)
        overview = OrgGraph::UnitsOverview.new
        payments = OrgUnit.find(@org[:payments])
        rights = OrgGraphPolicy::UnitRights.new(OrgGraphPolicy.new(context, :org_graph), payments, overview)

        assert_equal [ [ "Stream" ], [ "Checkout" ], false ], [ rights.type_choices.map(&:name), rights.parent_choices.map(&:name), rights.root_choice? ]
        assert_equal "Stream", overview.level_of(payments).name
      end
    end

    should "show the declaration and the withdrawal in the unit's activity, and change the withdrawal back" do
      call(Operations::OrgGraph::WithdrawStructure, unit_id: @org[:checkout], conversion: { @stream => @org[:squad] })

      ActsAsTenant.with_tenant(@tenant) do
        context = AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person)
        items = OrgGraph::ActivityFeed.new(unit: OrgUnit.find(@org[:checkout]), actor: context).items
        withdrawal, declaration = items.first(2)

        assert_equal [ "Withdrew its structure of Stream and Lane", "Gave it a structure of its own: Stream and Lane" ],
                     [ withdrawal, declaration ].map { it.parts.find { |part| part.entry.subject == "structure" }.description }
        assert_equal [ "withdrew its structure", "gave it a structure of its own" ], [ withdrawal, declaration ].map { it.group.summary.split(" and ").last }
        assert_equal [ nil, "A later change has replaced this one; change that back first" ], [ withdrawal, declaration ].map(&:refusal)
        assert_equal [ @admin.person.name ] * 2, [ withdrawal, declaration ].map { it.parts.find { |part| part.entry.subject == "structure" }.by }
      end

      ActsAsTenant.with_tenant(@tenant) do
        call(Operations::OrgGraph::ChangeBackGroup, cause_id: OrgUnitActivity.where(subject: "structure").order(:position).last.cause_id)
        assert_includes OrgGraph::Repository.new.load_structure.declared_structures.fetch(@org[:checkout]).kinds.map(&:id), @stream
      end
    end

    should "refuse to change a withdrawal back over a unit an HRIS has since supplied beneath it" do
      call(Operations::OrgGraph::WithdrawStructure, unit_id: @org[:checkout], conversion: { @stream => @org[:squad] })
      ActsAsTenant.with_tenant(@tenant) do
        handler = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        %i[team squad].each do |level|
          matches = OrgUnit.live.where(level_id: @org[level]).pluck(:id).to_h { [ it, "ref-#{it}" ] }
          handler.hand_over_level(@org[level], "hibob", field: "work.#{level}", matches:, effective_on: Tenant.today)
        end
      end

      cause_id = ActsAsTenant.with_tenant(@tenant) { OrgUnitActivity.where(subject: "structure").order(:position).last.cause_id }
      error = assert_raises(Operations::Base::ParameterError) { ActsAsTenant.with_tenant(@tenant) { call(Operations::OrgGraph::ChangeBackGroup, cause_id:) } }
      assert_match "Payments comes from", error.message
    end

    should "refuse to change back a type the withdrawal converted alone, as the request shares one cause" do
      AuditMetadata.with(acting_via: :web, correlation_id: SecureRandom.uuid_v7) do
        call(Operations::OrgGraph::WithdrawStructure, unit_id: @org[:checkout], conversion: { @stream => @org[:squad] })
      end

      ActsAsTenant.with_tenant(@tenant) do
        context = AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person)
        conversion = OrgUnitActivity.where(unit_id: @org[:payments], event_type: "UnitKindChanged").order(:created_at).last

        assert_equal "This came with a change to a unit's own structure, so change the whole change back",
                     OrgGraph::ChangeBackHandler.new(actor: context).refusal(conversion)
      end
    end

    context "MoveUnit with a conversion" do
      should "move a team into the structure, converting it, and keep its members" do
        members = members_of(:platform)
        result = move_in

        assert_equal({ @org[:team] => @stream }, result[:conversion])
        assert_equal [ @stream, @org[:checkout] ], ActsAsTenant.with_tenant(@tenant) { OrgUnit.find(@org[:platform]).then { [ it.level_id, it.parent_id ] } }
        assert_equal members, members_of(:platform)
      end

      should "learn the move and its type changes at one moment, so no cutoff shows it half made" do
        known = lambda do |at, on|
          ActsAsTenant.with_tenant(@tenant) do
            %w[parent level].map do |fact|
              OrgFactPeriod.known_at(at).in_effect_on(on)
                           .find_by(subject_type: OrgGraph::Projections::History::UNIT, subject_id: @org[:platform], fact:)
                           &.value&.values&.first
            end
          end
        end
        was = ActsAsTenant.with_tenant(@tenant) { OrgUnit.find(@org[:platform]).then { [ it.parent_id, it.level_id ] } }
        on = move_in[:effective_on]

        events = Rails.configuration.event_store.read.of_type([ OrgGraph::Events::UnitMoved, OrgGraph::Events::UnitKindChanged ]).to_a
        moved = events.reverse.find { it.is_a?(OrgGraph::Events::UnitMoved) }
        change = events.select { it.metadata[:correlation_id] == moved.metadata[:correlation_id] }
        assert_operator change.size, :>, 1
        assert_equal [ moved.timestamp ], change.map(&:timestamp).uniq
        learned = ActsAsTenant.with_tenant(@tenant) { OrgFactPeriod.where(event_id: change.map(&:event_id)).distinct.pluck(:learned_at) }
        assert_equal [ moved.timestamp ], learned
        assert_equal was, known.call(moved.timestamp - 0.000001, on)
        assert_equal [ @org[:checkout], @stream ], known.call(moved.timestamp, on)
      end

      should "refuse a misfit as a parameter error, and leave the move to a tenant admin" do
        error = assert_raises(Operations::Base::ParameterError) { move_in(conversion: { @org[:team] => @lane }) }
        assert_equal "These units wouldn't fit Checkout's structure: Platform (Lane at the top)", error.message

        error = assert_raises(OrgGraph::Authorization::Refused) { move_in(as: @editor) }
        assert_equal "Only a tenant admin can move a unit into another structure", error.message
        assert_equal @org[:team], level_of(:platform)
      end

      should "ask the caller to retry while the units are rebuilt, and name a unit that isn't there" do
        while_rebuilding(@tenant, OrgGraph::Projections::Structure) do
          error = assert_raises(Operations::Base::ParameterError) { move_in }
          assert_equal ProjectionVersion::Rebuilding.new.message, error.message
        end
        replay(@tenant, OrgGraph::Projections::Structure)
        assert_equal @org[:team], level_of(:platform)

        missing = SecureRandom.uuid_v7
        error = assert_raises(Operations::Base::ParameterError) do
          call(Operations::OrgGraph::MoveUnit, unit_id: missing, parent_id: @org[:checkout], conversion: { @org[:team] => @stream })
        end
        assert_equal "unit_id names no unit in the Org Graph", error.message
        error = assert_raises(Operations::Base::ParameterError) do
          call(Operations::OrgGraph::MoveUnit, unit_id: @org[:platform], parent_id: missing, conversion: { @org[:team] => @stream })
        end
        assert_equal "parent_id names no unit in the Org Graph", error.message
      end

      should "keep the command's refusal when a rebuild empties the units before it reaches the caller" do
        tenant = @tenant
        build = OrgGraph::StructureCommandHandler.method(:new)
        rebuilding_after_refusal = lambda do |**options|
          build.call(**options).tap do |handler|
            move = handler.method(:move_unit)
            handler.define_singleton_method(:move_unit) do |*args, **kwargs|
              move.call(*args, **kwargs)
            rescue RuntimeError
              OrgGraph::Projections::Structure.reset!(tenant:)
              raise
            end
          end
        end
        tomorrow = ActsAsTenant.with_tenant(@tenant) { Tenant.today + 1 }.iso8601

        error = OrgGraph::StructureCommandHandler.stub(:new, rebuilding_after_refusal) do
          assert_raises(Operations::Base::ParameterError) do
            call(Operations::OrgGraph::MoveUnit, unit_id: @org[:platform], parent_id: @org[:checkout],
                                                 effective_on: tomorrow, conversion: { @org[:team] => @stream })
          end
        end
        assert_equal "A move into another structure can't be dated after today", error.message
        replay(@tenant, OrgGraph::Projections::Structure)
      end

      should "name a retired unit or parent from the command's own state" do
        retired = ActsAsTenant.with_tenant(@tenant) do
          OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).tap do |handler|
            handler.retire_unit(@org[:payments], effective_on: Tenant.today.iso8601)
          end
          OrgUnit.find(@org[:payments]).name
        end
        [ [ @org[:payments], @org[:checkout] ], [ @org[:platform], @org[:payments] ] ].each do |unit_id, parent_id|
          error = assert_raises(Operations::Base::ParameterError) do
            call(Operations::OrgGraph::MoveUnit, unit_id:, parent_id:, conversion: { @org[:team] => @stream })
          end
          assert_equal "#{retired} is retired", error.message
        end
      end

      should "refuse an unknown or another tenant's unit with the ordinary message, naming no unit" do
        elsewhere = build_org_graph(create(:tenant))
        move = ->(as, unit_id, parent_id) { call(Operations::OrgGraph::MoveUnit, as:, unit_id:, parent_id:, conversion: { @org[:team] => @stream }) }
        [ SecureRandom.uuid_v7, elsewhere[:platform] ].each do |stranger|
          [ [ stranger, @org[:checkout] ], [ @org[:platform], stranger ] ].each do |unit_id, parent_id|
            error = assert_raises(OrgGraph::Authorization::Refused) { move.call(@editor, unit_id, parent_id) }
            assert_equal "Only a tenant admin can move a unit into another structure", error.message

            error = assert_raises(Operations::Base::ParameterError) { move.call(@admin, unit_id, parent_id) }
            named = unit_id == stranger ? "unit_id" : "parent_id"
            assert_equal "#{named} names no unit in the Org Graph", error.message
          end
        end
        assert_equal @org[:team], level_of(:platform)
      end

      should "return the date it wrote when the tenant's day turns over mid-call" do
        today = ActsAsTenant.with_tenant(@tenant) { Tenant.today }
        days = [ today, today + 1 ]
        result = Tenant.stub(:today, -> { days.shift || today + 1 }) { move_in }

        written = Rails.configuration.event_store.read.of_type(OrgGraph::Events::UnitMoved).last.data[:effective_on]
        assert_equal written, result[:effective_on]
      end

      should "refuse a malformed conversion before the operation runs, so MCP saves no approval for it" do
        build = lambda do |conversion|
          ActsAsTenant.with_tenant(@tenant) do
            context = AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person)
            Operations::OrgGraph::MoveUnit.new(context:, params: { unit_id: @org[:platform], parent_id: @org[:checkout], conversion: })
          end
        end

        error = assert_raises(Operations::Base::ParameterError) { build.call({ @org[:team] => true }) }
        assert_equal "conversion maps level ids to level ids, got #{@org[:team].inspect} => true", error.message
        assert_raises(Operations::Base::ParameterError) { build.call({ "Team" => @stream }) }
        error = assert_raises(Operations::Base::ParameterError) { build.call({}) }
        assert_equal "conversion can't be blank", error.message
        assert_equal @org[:team], level_of(:platform)
      end

      should "refuse a conversion on a move to the top of the organisation's structure from inside it" do
        error = assert_raises(Operations::Base::ParameterError) do
          call(Operations::OrgGraph::MoveUnit, unit_id: @org[:platform], conversion: { @org[:team] => @org[:team] })
        end
        assert_equal "Platform stays in the organisation's structure, so the move takes no conversion", error.message
        assert_equal @org[:team], level_of(:platform)
      end

      should "refuse two spellings of one type that map to different types, and accept one in capitals" do
        error = assert_raises(Operations::Base::ParameterError) do
          move_in(conversion: { @org[:team].upcase => @stream, @org[:team] => @lane })
        end
        assert_equal "conversion gives #{@org[:team]} two different types", error.message
        assert_equal @org[:team], level_of(:platform)

        assert_equal({ @org[:team] => @stream }, move_in(conversion: { @org[:team].upcase => @stream.upcase })[:conversion])
        assert_equal @stream, level_of(:platform)
      end
    end
  end
end
