# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class OrgGraph::Projections::MembersTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  PROVENANCE = { provider: "espalia", effective_on: "2026-02-01" }.freeze

  setup do
    @tenant = create(:tenant)
    @handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    level = SecureRandom.uuid_v7
    @payments = SecureRandom.uuid_v7
    @platform = SecureRandom.uuid_v7

    as_tenant do
      @ada, @grace, @linus = create_list(:person, 3, tenant: @tenant)
      structure.define_taxonomy([ { level_id: level, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: level, effective_on: "2026-01-01")
      structure.create_unit(@platform, "Platform", level_id: level, effective_on: "2026-01-01")
      [ @ada, @grace, @linus ].each { |person| @handler.record_person(person.id, **PROVENANCE, employment_status: "employed") }

      @handler.set_membership(@ada.id, @payments, allocation: 0.6, role: "Tech lead", **PROVENANCE)
      @handler.set_membership(@ada.id, @platform, allocation: 0.4, **PROVENANCE)
      @handler.set_membership(@grace.id, @payments, provider: "espalia", effective_on: "2026-03-01")
    end
  end

  should "list a unit's current members, each with their own allocation and role" do
    as_tenant do
      payments = OrgUnit.find(@payments)
      assert_equal [ @ada, @grace ].map(&:id).sort, payments.members.pluck(:id).sort

      ada = payments.memberships.find_by!(person: @ada)
      assert_equal [ 0.6, "Tech lead", "espalia" ], [ ada.allocation, ada.role, ada.provider ]
      assert_in_delta 0.4, OrgUnit.find(@platform).memberships.find_by!(person: @ada).allocation
      assert_nil payments.memberships.find_by!(person: @grace).allocation
    end
  end

  should "keep when a membership began through a change of terms, and drop it when it ends" do
    as_tenant do
      @handler.set_membership(@ada.id, @payments, allocation: 1, provider: "espalia", effective_on: "2026-05-01")
      ada = OrgMembership.find_by!(person: @ada, unit_id: @payments)
      assert_equal [ Date.new(2026, 2, 1), Date.new(2026, 5, 1), 1.0 ], [ ada.member_since, ada.effective_on, ada.allocation ]

      @handler.end_membership(@ada.id, @payments, provider: "espalia", effective_on: "2026-06-30")
      assert_equal [ @grace.id ], OrgUnit.find(@payments).members.pluck(:id)
      assert_equal [ @platform ], OrgMembership.where(person: @ada).pluck(:unit_id)
    end
  end

  should "hold the allocation exactly as the event does" do
    as_tenant do
      @handler.set_membership(@linus.id, @platform, allocation: 1.0 / 3, **PROVENANCE)
      stored = OrgMembership.find_by!(person: @linus).allocation

      assert_equal 1.0 / 3, stored
      assert_nothing_raised { @handler.set_membership(@linus.id, @platform, allocation: stored, **PROVENANCE) }
      assert_equal 1, OrgMembership.where(person: @linus).count
    end
  end

  should "move a membership's start earlier when a set is backdated" do
    as_tenant do
      @handler.set_membership(@grace.id, @payments, allocation: 0.5, provider: "espalia", effective_on: "2026-01-15")

      assert_equal Date.new(2026, 1, 15), OrgMembership.find_by!(person: @grace).member_since
    end
  end

  should "list the people in no live unit" do
    as_tenant do
      assert_equal [ @linus.id ], Person.in_no_unit.pluck(:id)

      OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).retire_unit(@payments, effective_on: "2026-06-30")
      assert_equal [ @grace.id, @linus.id ].sort, Person.in_no_unit.pluck(:id).sort
    end
  end

  should "move a member to another unit, keeping when their membership began" do
    as_tenant do
      @handler.move_membership(@grace.id, @payments, @platform, effective_on: "2026-05-01")
      moved = OrgMembership.find_by!(person_id: @grace.id, unit_id: @platform)

      assert_not OrgMembership.exists?(person_id: @grace.id, unit_id: @payments)
      assert_equal [ "espalia", Date.new(2026, 3, 1), Date.new(2026, 5, 1) ],
                   [ moved.provider, moved.member_since, moved.effective_on ]
    end
  end

  should "keep when a membership began once its ending is changed back" do
    as_tenant do
      @handler.end_membership(@grace.id, @payments, provider: "espalia", effective_on: "2026-05-01")
      OrgGraph::ChangeBackHandler.new(actor: OrgGraph::Authorization::SYSTEM).change_back(OrgUnitActivity.for_unit(@payments).first)

      assert_equal Date.new(2026, 3, 1), OrgMembership.find_by!(person_id: @grace.id, unit_id: @payments).member_since
    end
  end

  context "rebuild contract" do
    should "reset! + replay produce identical read-model state, including the stable ids" do
      as_tenant do
        @handler.set_membership(@grace.id, @payments, allocation: 0.5, provider: "espalia", effective_on: "2026-04-01")
        @handler.end_membership(@ada.id, @platform, **PROVENANCE)
        @handler.set_membership(@ada.id, @platform, role: "Reviewer", provider: "espalia", effective_on: "2026-07-01")
        @handler.move_membership(@grace.id, @payments, @platform, effective_on: "2026-08-01")
        request = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM, cause_id: "request-1")
        request.set_membership(@ada.id, @payments, allocation: 0.8, provider: "espalia", effective_on: "2026-09-01")
        request.set_membership(@ada.id, @payments, allocation: 0.7, provider: "espalia", effective_on: "2026-10-01")
        OrgGraph::ChangeBackHandler.new(actor: OrgGraph::Authorization::SYSTEM).change_back_group("request-1")
      end

      before = snapshot_read_models(OrgGraph::Projections::Members, @tenant)
      assert_equal 3, before[:memberships].size

      OrgGraph::Projections::Members.reset!(tenant: @tenant)
      as_tenant { assert_equal 0, OrgMembership.count }

      Projections::Replayer.replay(projection_class: OrgGraph::Projections::Members, tenant: @tenant)

      assert_equal before, snapshot_read_models(OrgGraph::Projections::Members, @tenant)
    end

    should "leave another tenant's memberships alone on reset!" do
      other = create(:tenant)
      ActsAsTenant.with_tenant(other) do
        level = SecureRandom.uuid_v7
        unit = SecureRandom.uuid_v7
        person = create(:person, tenant: other)
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).define_taxonomy([ { level_id: level, name: "Squad" } ], effective_on: "2026-01-01")
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).create_unit(unit, "Squad", level_id: level, effective_on: "2026-01-01")
        @handler.record_person(person.id, **PROVENANCE, employment_status: "employed")
        @handler.set_membership(person.id, unit, **PROVENANCE)
      end

      OrgGraph::Projections::Members.reset!(tenant: @tenant)

      ActsAsTenant.with_tenant(other) { assert_equal 1, OrgMembership.count }
    end
  end

  private

  def as_tenant(&block)
    ActsAsTenant.with_tenant(@tenant, &block)
  end
end
