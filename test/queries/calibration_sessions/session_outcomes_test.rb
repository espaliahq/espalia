# frozen_string_literal: true

require "test_helper"

class CalibrationSessions::SessionOutcomesTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @dept_head = create(:person, tenant: @tenant)
    em = create(:person, tenant: @tenant, manager: @dept_head)
    report = create(:person, tenant: @tenant, manager: em)
    cycle = create(:assessment_cycle, tenant: @tenant)
    user = create(:user)
    @context = AuthorizationContext.new(
      user: user, tenant_user: create(:tenant_user, user: user, tenant: @tenant, person: @dept_head),
      person: @dept_head
    )
    @session_id = Operations::CalibrationSessions::Define.call(
      context: @context,
      params: { cycle_id: cycle.cycle_id, name: "Eng", participant_ids: [ em.id ],
                calibrant_person_ids: [ report.id ] }
    )[:session_id]
    dispatch(:Start)
    dispatch(:RecordNote, body: "A minute")
    dispatch(:Close)
    dispatch(:Rename, name: "Eng · H1")
    dispatch(:Archive)
    dispatch(:Unarchive)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def dispatch(operation, **params)
    Operations::CalibrationSessions.const_get(operation).call(
      context: @context, params: { session_id: @session_id, **params }
    )
  end

  def outcomes
    CalibrationSessions::SessionOutcomes.new(session: CalibrationSession.find(@session_id))
  end

  should "read renames, archives and restores as lifecycle entries with their actor" do
    lifecycle = outcomes.lifecycle

    assert_equal %w[session_renamed session_archived session_restored], lifecycle.map { |e| e[:kind] }
    assert_equal [ @dept_head.id ], lifecycle.map { |e| e[:actor_id] }.uniq
    assert_equal({ name: "Eng · H1", previous_name: "Eng" }, lifecycle.first.slice(:name, :previous_name))
  end

  should "interleave them into the feed, newest first" do
    assert_equal %w[session_restored session_archived session_renamed note_recorded],
                 outcomes.entries.map { |e| e[:kind] }
  end

  should "count outcomes only" do
    session = CalibrationSession.find(@session_id)
    assert_equal 1, outcomes.count
    assert_equal({ @session_id => 1 }, CalibrationSessions::SessionOutcomes.counts_for([ session ]))
  end
end
