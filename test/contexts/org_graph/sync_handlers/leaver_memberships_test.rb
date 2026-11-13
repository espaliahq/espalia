# frozen_string_literal: true

require "test_helper"

class OrgGraph::SyncHandlers::LeaverMembershipsTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2026-02-01" }.freeze

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
      @people.set_membership(@ada.id, @payments, allocation: 0.6, **ESPALIA)
      @people.set_membership(@ada.id, @billing, allocation: 0.4, **ESPALIA)
      @people.set_membership(@grace.id, @payments, **ESPALIA)
    end
  end

  context "a person who leaves" do
    setup { as_tenant { @people.leave(@ada.id, provider: "espalia", effective_on: "2026-06-30") } }

    should "end every open membership with the leaving date as its effective date" do
      ended = ada_events.grep(OrgGraph::Events::MembershipEnded)

      assert_equal [ [ @billing, "2026-06-30" ], [ @payments, "2026-06-30" ] ].sort,
                   ended.map { it.data.values_at(:unit_id, :effective_on) }.sort
      as_tenant { assert_not OrgMembership.exists?(person_id: @ada.id) }
    end

    should "leave everyone else's memberships alone" do
      as_tenant { assert OrgMembership.exists?(person_id: @grace.id, unit_id: @payments) }
    end

    should "carry the leaving as each end's cause" do
      left = ada_events.grep(OrgGraph::Events::PersonLeft).sole
      ended = ada_events.grep(OrgGraph::Events::MembershipEnded)

      assert(ended.all? { it.metadata[:causation_id] == left.event_id })
      assert(ended.all? { it.metadata[:correlation_id] == left.metadata[:correlation_id] })
    end

    should "come back with no membership when they return" do
      as_tenant do
        @people.return_to_work(@ada.id, provider: "espalia", effective_on: "2026-09-01")

        assert_not OrgMembership.exists?(person_id: @ada.id)
        assert_includes Person.in_no_unit, @ada
      end
      assert_kind_of OrgGraph::Events::PersonReturned, ada_events.last
    end

    should "end nothing again when a later sync corrects the leaving date" do
      as_tenant do
        assert_difference -> { ada_events.size }, 1 do
          @people.leave(@ada.id, provider: "espalia", effective_on: "2026-07-15")
        end
      end
      assert_kind_of OrgGraph::Events::PersonLeft, ada_events.last
    end
  end

  should "end a membership that changed after a backdated leaving on the day it changed" do
    as_tenant do
      @people.set_membership(@ada.id, @payments, allocation: 0.5, **ESPALIA, effective_on: "2026-08-01")
      @people.leave(@ada.id, provider: "espalia", effective_on: "2026-07-01")
    end

    ended = ada_events.grep(OrgGraph::Events::MembershipEnded).to_h { [ it.data[:unit_id], it.data[:effective_on] ] }
    assert_equal({ @payments => "2026-08-01", @billing => "2026-07-01" }, ended)
  end

  should "end the memberships of someone the absence pass marks as left" do
    as_tenant { @people.record_absence(@grace.id, provider: "espalia", effective_on: "2026-05-04") }

    ended = person_events(@grace).grep(OrgGraph::Events::MembershipEnded).sole
    assert_equal [ @payments, "2026-05-04" ], ended.data.values_at(:unit_id, :effective_on)
  end

  should "end the memberships of someone a sync reports as left, on their termination date" do
    as_tenant do
      @people.sync_person(@grace.id, provider: "espalia", effective_on: "2026-05-04",
                                     employment_status: "left", left_on: "2026-04-30")
    end

    ended = person_events(@grace).grep(OrgGraph::Events::MembershipEnded).sole
    assert_equal [ @payments, "2026-04-30" ], ended.data.values_at(:unit_id, :effective_on)
  end

  should "roll the leaving back when its memberships can't be ended" do
    failing = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    failing.define_singleton_method(:end_memberships) { |*, **| raise "member command failed" }

    as_tenant do
      OrgGraph::CommandHandler.stub(:new, failing) do
        assert_raises(RuntimeError, match: /member command failed/) do
          @people.leave(@ada.id, provider: "espalia", effective_on: "2026-06-30")
        end
      end
    end

    assert_not(ada_events.any?(OrgGraph::Events::PersonLeft))
    as_tenant { assert_equal 2, OrgMembership.where(person_id: @ada.id).count }
  end

  should "leave a unit whose only owner left flagged as having none, writing no ownership change" do
    as_tenant do
      @structure.add_unit_owner(@billing, @ada.id, effective_on: "2026-02-01")
      @people.leave(@ada.id, provider: "espalia", effective_on: "2026-06-30")
      @ada.update!(status: "inactive")

      assert OrgUnit.find(@billing).needs_owner?
    end
    assert_not(structure_events.any?(OrgGraph::Events::UnitOwnerRemoved))
  end

  private

  def as_tenant(&block)
    ActsAsTenant.with_tenant(@tenant, &block)
  end

  def ada_events = person_events(@ada)

  def person_events(person)
    Rails.configuration.event_store.read.stream(EventStreamNaming.person_stream(person.id, tenant: @tenant)).to_a
  end

  def structure_events
    Rails.configuration.event_store.read.stream(EventStreamNaming.org_structure_stream(tenant: @tenant)).to_a
  end
end
