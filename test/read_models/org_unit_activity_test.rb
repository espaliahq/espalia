# frozen_string_literal: true

require "test_helper"

class OrgUnitActivityTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2026-02-01" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant)
    @team = SecureRandom.uuid_v7
    @payments, @billing, @ledger, @platform = Array.new(4) { SecureRandom.uuid_v7 }
    as_tenant do
      @people = create_list(:person, 3, tenant: @tenant)
      structure.define_taxonomy([ { level_id: @team, name: "Team" } ], effective_on: "2026-01-01")
      [ [ @payments, "Payments" ], [ @billing, "Billing" ], [ @ledger, "Ledger" ], [ @platform, "Platform" ] ].each do |id, name|
        structure.create_unit(id, name, level_id: @team, effective_on: "2026-01-01")
      end
      @people.each do |person|
        people.record_person(person.id, **ESPALIA, employment_status: "employed")
        people.set_membership(person.id, @payments, **ESPALIA)
      end
    end
  end

  context ".feed" do
    should "fold an approved split into one entry naming the reorganisation and its plan change" do
      ada, grace, = @people
      as_tenant do
        structure(cause_id: "approval-1").apply_succession(
          SecureRandom.uuid_v7, predecessor_ids: [ @payments ], successor_ids: [ @billing, @ledger ],
          placements: { ada.id => @billing, grace.id => @ledger }, effective_on: "2026-07-01",
          plan_id: "plan-7", plan_change_id: "change-3"
        )
      end

      split, *earlier = feed(@payments)
      assert_equal "split Payments into Billing and Ledger", split.summary
      assert_equal %w[approval-1 plan-7 change-3], [ split.cause_id, split.plan_id, split.plan_change_id ]
      assert_equal %w[MembershipEnded MembershipMoved MembershipMoved UnitRetired UnitSucceeded].sort,
        split.parts.map(&:event_type).sort
      assert(earlier.all? { |entry| entry.parts.one? })
      assert_equal "split Payments into Billing and Ledger", feed(@billing).first.summary
    end

    should "count repeated changes of one kind, and read a direct edit as an entry of its own" do
      as_tenant do
        moves = people(cause_id: "request-1")
        @people.first(2).each { |person| moves.move_membership(person.id, @payments, @platform, effective_on: "2026-03-01") }
        moves.end_membership(@people.last.id, @payments, **ESPALIA)
        structure.rename_unit(@payments, "Payments Core", effective_on: "2026-03-02")
      end

      renamed, request = feed(@payments)
      assert_equal "renamed it from Payments to Payments Core", renamed.summary
      assert_equal "moved 2 people out and removed 1 person", request.summary
      assert_nil request.plan_id
      assert_equal "moved 2 people in", feed(@platform).first.summary
    end

    should "count people rather than changes, so one person's two changes read as one" do
      as_tenant do
        terms = people(cause_id: "request-1")
        [ 0.5, 0.8 ].each { |allocation| terms.set_membership(@people.first.id, @payments, **ESPALIA, allocation:) }
      end

      assert_equal "changed the terms of 1 person", feed(@payments).first.summary
    end

    should "say a handover hands the unit to its provider and field, and back" do
      matches = { @payments => "work.team/1", @billing => "work.team/2", @ledger => "work.team/3", @platform => "work.team/4" }
      as_tenant do
        structure(cause_id: "handover-1").hand_over_level(@team, "hibob", field: "work.team", matches:, effective_on: "2026-07-01")
        structure(cause_id: "handover-2").hand_back_level(@team, effective_on: "2026-07-02")
      end

      back, over, = feed(@payments)
      assert_equal [ "handed it back to Espalia", "handed it to HiBob, read from work.team" ], [ back.summary, over.summary ]
      assert_equal [ "handover-2", "handover-1" ], [ back.cause_id, over.cause_id ]
    end

    should "page by entry, so a page never splits one cause" do
      as_tenant do
        moves = people(cause_id: "request-1")
        @people.each { |person| moves.move_membership(person.id, @payments, @platform, effective_on: "2026-03-01") }
      end

      first_page = as_tenant { OrgUnitActivity.feed(@payments, per_page: 1) }
      second_page = as_tenant { OrgUnitActivity.feed(@payments, page: 2, per_page: 1) }
      assert_equal [ "moved 3 people out" ], first_page.map(&:summary)
      assert_equal [ "added 1 person" ], second_page.map(&:summary)
      assert_equal first_page.map(&:cause_id), as_tenant { OrgUnitActivity.feed(@payments, page: 0, per_page: 1) }.map(&:cause_id)
    end
  end

  private

  def feed(unit_id) = as_tenant { OrgUnitActivity.feed(unit_id) }

  def structure(cause_id: nil) = OrgGraph::StructureCommandHandler.new(actor: SYSTEM, cause_id:)

  def people(cause_id: nil) = OrgGraph::CommandHandler.new(actor: SYSTEM, cause_id:)

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)
end
