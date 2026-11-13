# frozen_string_literal: true

require "test_helper"

class OrgGraph::PlanReferenceTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2026-02-01" }.freeze
  PLAN = { plan_id: "plan-7", plan_change_id: "change-3" }.freeze

  setup do
    @tenant = create(:tenant)
    @structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @team_level = SecureRandom.uuid_v7
    @payments, @billing = Array.new(2) { SecureRandom.uuid_v7 }

    as_tenant do
      @ada, @grace = create_list(:person, 2, tenant: @tenant)
      @structure.define_taxonomy([ { level_id: @team_level, name: "Team" } ], effective_on: "2026-01-01")
      @structure.create_unit(@payments, "Payments", level_id: @team_level, effective_on: "2026-01-01")
      @structure.create_unit(@billing, "Billing", level_id: @team_level, effective_on: "2026-01-01")
      [ @ada, @grace ].each { |person| @people.record_person(person.id, **ESPALIA, employment_status: "employed") }
    end
  end

  context "a command given a plan reference" do
    should "write it on a person fact's event" do
      as_tenant { @people.change_title(@ada.id, "Staff engineer", **ESPALIA, **PLAN) }

      assert_equal PLAN, person_events(@ada).last.data.slice(:plan_id, :plan_change_id)
    end

    should "write it on every event one command writes" do
      as_tenant { @people.apply_facts(@ada.id, **ESPALIA, title: "Staff engineer", level: "L5", **PLAN) }

      written = person_events(@ada).last(2)
      assert_equal [ OrgGraph::Events::TitleChanged, OrgGraph::Events::LevelChanged ], written.map(&:class)
      assert(written.all? { |event| event.data.slice(:plan_id, :plan_change_id) == PLAN })
    end

    should "write it on a membership and on a structure event" do
      as_tenant do
        @people.set_membership(@ada.id, @payments, **ESPALIA, **PLAN)
        @structure.rename_unit(@payments, "Payments core", effective_on: "2026-03-01", **PLAN)
      end

      assert_equal PLAN, person_events(@ada).last.data.slice(:plan_id, :plan_change_id)
      assert_equal PLAN, structure_events.last.data.slice(:plan_id, :plan_change_id)
    end

    should "write it on the moves a retirement makes for its members" do
      as_tenant do
        @people.set_membership(@ada.id, @payments, **ESPALIA)
        @structure.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @payments ], successor_ids: [ @billing ],
                                                           effective_on: "2026-06-30", retire_predecessors: true, **PLAN)
      end

      moved = person_events(@ada).last
      assert_instance_of OrgGraph::Events::MembershipMoved, moved
      assert_equal PLAN, moved.data.slice(:plan_id, :plan_change_id)
    end

    should "refuse a key it doesn't know" do
      as_tenant do
        assert_raises(ArgumentError) { @people.change_title(@ada.id, "Staff engineer", **ESPALIA, plan: "plan-7") }
      end
    end
  end

  context "a command given no plan reference" do
    should "write none, so the change reads as direct" do
      as_tenant do
        @people.change_title(@ada.id, "Staff engineer", **ESPALIA)
        @structure.rename_unit(@payments, "Payments core", effective_on: "2026-03-01")
      end

      assert_not person_events(@ada).last.data.key?(:plan_id)
      assert_nil structure_events.last.data[:plan_id]
      assert_nil structure_events.last.data[:plan_change_id]
    end
  end

  context "a handler given a cause" do
    should "give every event it writes, a sync handler's included, the cause as their correlation id" do
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM, cause_id: "approval-1")
      people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM, cause_id: "approval-1")

      as_tenant { @people.set_membership(@grace.id, @payments, **ESPALIA) }
      AuditMetadata.with(acting_via: :web, correlation_id: "request-1") do
        AuditMetadata.wrap_event_store do
          as_tenant do
            people.change_title(@ada.id, "Staff engineer", **ESPALIA)
            structure.retire_unit(@payments, effective_on: "2026-06-30")
          end
        end
      end

      written = [ person_events(@ada).last, structure_events.last, person_events(@grace).last ]
      assert_equal [ OrgGraph::Events::TitleChanged, OrgGraph::Events::UnitRetired, OrgGraph::Events::MembershipEnded ],
                   written.map(&:class)
      assert_equal [ "approval-1" ] * 3, written.map { |event| event.metadata[:correlation_id] }
    end
  end

  context "a handler given no cause" do
    should "keep the request's correlation id, so a later change reads apart from the plan's" do
      planned = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM, cause_id: "approval-1")

      AuditMetadata.with(acting_via: :web, correlation_id: "request-1") do
        AuditMetadata.wrap_event_store { as_tenant { planned.change_title(@ada.id, "Staff engineer", **ESPALIA) } }
      end
      AuditMetadata.with(acting_via: :web, correlation_id: "request-2") do
        AuditMetadata.wrap_event_store { as_tenant { @people.change_title(@ada.id, "Engineer", **ESPALIA) } }
      end

      assert_equal %w[approval-1 request-2], person_events(@ada).last(2).map { |event| event.metadata[:correlation_id] }
    end

    should "treat a blank cause as none" do
      blank = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM, cause_id: "")

      AuditMetadata.with(acting_via: :web, correlation_id: "request-1") do
        AuditMetadata.wrap_event_store { as_tenant { blank.change_title(@ada.id, "Staff engineer", **ESPALIA) } }
      end

      assert_equal "request-1", person_events(@ada).last.metadata[:correlation_id]
    end
  end

  private

  def as_tenant(&block)
    ActsAsTenant.with_tenant(@tenant, &block)
  end

  def person_events(person)
    Rails.configuration.event_store.read.stream(EventStreamNaming.person_stream(person.id, tenant: @tenant)).to_a
  end

  def structure_events
    Rails.configuration.event_store.read.stream(EventStreamNaming.org_structure_stream(tenant: @tenant)).to_a
  end
end
