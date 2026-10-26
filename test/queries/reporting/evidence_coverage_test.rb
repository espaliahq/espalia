# frozen_string_literal: true

require "test_helper"

class Reporting::EvidenceCoverageTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7
    @role = create(:framework_role, name: "Engineer")
    @manager = create(:person, tenant: @tenant, name: "Manager")
    @other_manager = create(:person, tenant: @tenant, name: "Other Manager")
    @peer = create(:person, tenant: @tenant, name: "Feedback Author")
    @first = create(:person, tenant: @tenant, name: "First", manager: @manager)
    @second = create(:person, tenant: @tenant, name: "Second", manager: @other_manager)
    @cycle = create(:assessment_cycle,
      tenant: @tenant, framework_id: @framework_id, opened_at: 10.days.ago)
    enroll(@first)
    enroll(@second)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  context "current cycle metrics" do
    setup do
      proactive = feedback(person: @first)
      EvidenceLink.create!(
        tenant: @tenant, evidence_item: proactive, person_id: @first.id,
        framework_id: @framework_id, capability_stable_id: SecureRandom.uuid_v7,
        level_ordinal: 4, linked_by_id: @peer.id, linked_at: Time.current)

      requested = feedback(person: @first)
      request(person: @first, status: "responded", evidence_id: requested.id,
        requested_at: 1.minute.ago)
      feedback(person: @first, status: "withdrawn")
      request(person: @first, status: "pending")
      request(person: @first, status: "cancelled")

      feedback(person: @second)
      request(person: @second, status: "declined")
    end

    should "count unique active feedback and split requested and proactive feedback" do
      metrics = result.metrics
      assert_equal 3, metrics.feedback_provided
      assert_equal 1, metrics.provided_by_request
      assert_equal 2, metrics.provided_unsolicited
      assert_equal 1, metrics.feedback_withdrawn
    end

    should "report request statuses and rates using non-cancelled requests" do
      metrics = result.metrics
      assert_equal 4, metrics.requests_sent
      assert_equal 1, metrics.requests_fulfilled
      assert_equal 1, metrics.requests_pending
      assert_equal 1, metrics.requests_declined
      assert_equal 1, metrics.requests_cancelled
      assert_equal 33, metrics.request_fulfillment_pct
    end

    should "report participant coverage" do
      assert_equal 2, result.metrics.participant_count
      assert_equal 2, result.metrics.participants_with_feedback
      assert_equal 100, result.metrics.participant_coverage_pct
    end

    should "group by live manager and enrollment role and level" do
      assert_equal [ "Manager", "Other Manager" ], result.groups[:manager].map(&:label).sort
      assert_equal 2, result.groups[:role].first.metrics.participant_count
      assert_equal "Level 2", result.groups[:level].first.label
    end

    should "scope the report to selected participants" do
      scoped = Reporting::EvidenceCoverage.new(
        cycle: @cycle, scope_person_ids: [ @first.id ]
      ).call

      assert_equal 1, scoped.metrics.participant_count
      assert_equal 2, scoped.metrics.feedback_provided
      assert_equal 3, scoped.metrics.requests_sent
    end

    should "omit grouped detail in summary mode" do
      summary = Reporting::EvidenceCoverage.new(cycle: @cycle, mode: :summary).call
      assert_empty summary.groups
      assert_equal 3, summary.metrics.feedback_provided
    end
  end

  context "feedback directionality" do
    setup do
      feedback(person: @first, source: "manager", feedback_direction: "manager_to_report")
      feedback(person: @first, source: "peer", feedback_direction: "peer_to_peer")
      feedback(person: @second, source: "peer", feedback_direction: "report_to_manager")
      feedback(person: @second, source: "self", feedback_direction: "self")
      feedback(person: @first, source: "peer", feedback_direction: nil)
      feedback(person: @second, source: "manager", feedback_direction: nil)
      feedback(person: @second, status: "withdrawn", source: "peer",
        feedback_direction: "report_to_manager")
    end

    should "count active immutable directions and preserve historical peer ambiguity" do
      directionality = result.metrics.directionality

      assert_equal 6, result.metrics.feedback_provided
      assert_equal 5, directionality.interpersonal_total
      assert_equal 2, directionality.manager_to_report
      assert_equal 1, directionality.peer_to_peer
      assert_equal 1, directionality.report_to_manager
      assert_equal 1, directionality.legacy_peer_or_upward
      assert_equal 1, directionality.self_provided
      assert_equal 40, directionality.percentage_for(:manager_to_report)
      assert_equal 20, directionality.percentage_for(:peer_to_peer)
      assert_equal 20, directionality.percentage_for(:report_to_manager)
      assert_equal 20, directionality.percentage_for(:legacy_peer_or_upward)
    end

    should "count what the recipient wrote as self feedback, though recorded as peer" do
      feedback(person: @first, author: @first, source: "peer", feedback_direction: "peer_to_peer")
      directionality = result.metrics.directionality

      assert_equal 1, directionality.peer_to_peer
      assert_equal 2, directionality.self_provided
    end
  end

  context "origin" do
    setup do
      feedback(person: @first)
      feedback(person: @first, external_reference: { system: "kudos" })
      feedback(person: @first, external_reference: { system: "github", url: "https://github.com/o/r/pull/1" })
      feedback(person: @second, external_reference: { system: "chip", metadata: { request_context: "Q3 check-in" } })
      feedback(person: @second, external_reference: { system: "chip" })
      feedback(person: @second, status: "withdrawn", external_reference: { system: "chip" })
    end

    should "split provided feedback by the system it was given in, GrowthOS first" do
      by_origin = result.metrics.by_origin

      assert_equal({ "growthos" => 2, "chip" => 2, "kudos" => 1 }, by_origin)
      assert_equal %w[growthos chip kudos], by_origin.keys
      assert_equal result.metrics.feedback_provided, by_origin.values.sum
    end

    should "report GrowthOS as zero rather than omit it" do
      only_peer = Reporting::EvidenceCoverage.new(cycle: @cycle, scope_person_ids: [ @second.id ]).call
      assert_equal({ "growthos" => 0, "chip" => 2 }, only_peer.metrics.by_origin)

      nobody = Reporting::EvidenceCoverage.new(cycle: @cycle, scope_person_ids: [ SecureRandom.uuid ]).call
      assert_equal({ "growthos" => 0 }, nobody.metrics.by_origin)
    end

    should "carry the split into each group" do
      by_manager = result.groups[:manager].index_by(&:label)

      assert_equal({ "growthos" => 2, "kudos" => 1 }, by_manager["Manager"].metrics.by_origin)
      assert_equal({ "growthos" => 0, "chip" => 2 }, by_manager["Other Manager"].metrics.by_origin)
    end

    should "count an imported peer that shares a link target's slug as that peer" do
      feedback(person: @first, external_reference: { system: "slack", metadata: { given_at: "2026-10-18T03:12:44Z" } })

      assert_equal 1, result.metrics.by_origin["slack"]
      assert_equal 2, result.metrics.by_origin["growthos"]
    end

    should "count a blank system as GrowthOS" do
      feedback(person: @first, external_reference: { system: "" })

      assert_equal 3, result.metrics.by_origin["growthos"]
    end
  end

  context "monthly reporting period" do
    setup do
      @this_month = Time.current.beginning_of_month
      @last_month = @this_month.prev_month
      @cycle.update!(opened_at: @last_month)

      feedback(person: @first, recorded_at: @last_month + 3.days)
      feedback(person: @first, recorded_at: @this_month + 2.hours)
      feedback(person: @second, recorded_at: @this_month + 3.hours, status: "withdrawn")
      request(person: @first, status: "responded", requested_at: @last_month + 1.day,
        evidence_id: feedback(person: @first, recorded_at: @this_month + 4.hours).id)
      request(person: @second, status: "pending", requested_at: @this_month + 1.hour)
    end

    should "count feedback recorded and requests sent inside the period" do
      report = Reporting::EvidenceCoverage.new(cycle: @cycle, period: @this_month.all_month).call

      assert_equal @this_month.all_month, report.period
      assert_equal 2, report.metrics.feedback_provided
      assert_equal 1, report.metrics.provided_by_request
      assert_equal 1, report.metrics.feedback_withdrawn
      assert_equal 1, report.metrics.participants_with_feedback
      assert_equal 50, report.metrics.participant_coverage_pct
      assert_equal 1, report.metrics.requests_sent
      assert_equal 1, report.metrics.requests_pending
    end

    should "keep a request sent in the period fulfilled even when answered later" do
      report = Reporting::EvidenceCoverage.new(cycle: @cycle, period: @last_month.all_month).call

      assert_equal 1, report.metrics.feedback_provided
      assert_equal 0, report.metrics.provided_by_request
      assert_equal 1, report.metrics.requests_sent
      assert_equal 1, report.metrics.requests_fulfilled
      assert_equal 100, report.metrics.request_fulfillment_pct
    end

    should "report the whole cycle with a nil period" do
      report = result

      assert_nil report.period
      assert_equal 3, report.metrics.feedback_provided
      assert_equal 2, report.metrics.requests_sent
    end
  end

  context "immutable provision attribution" do
    should "not count prior-cycle evidence that is relinked in this cycle" do
      previous = create(:assessment_cycle, :closed,
        tenant: @tenant, framework_id: @framework_id,
        opened_at: 30.days.ago, closed_at: 11.days.ago)
      old_item = feedback(person: @first, cycle_id: previous.cycle_id, recorded_at: 20.days.ago)
      EvidenceLink.create!(
        tenant: @tenant, evidence_item: old_item, person_id: @first.id,
        framework_id: @framework_id, capability_stable_id: SecureRandom.uuid_v7,
        level_ordinal: 5, linked_by_id: @manager.id, linked_at: Time.current)

      assert_equal 0, result.metrics.feedback_provided
    end

    should "count a request fulfilled with old evidence without counting new feedback" do
      previous = create(:assessment_cycle, :closed,
        tenant: @tenant, framework_id: @framework_id,
        opened_at: 30.days.ago, closed_at: 11.days.ago)
      old_item = feedback(person: @first, cycle_id: previous.cycle_id, recorded_at: 20.days.ago)
      request(person: @first, status: "responded", evidence_id: old_item.id)

      assert_equal 1, result.metrics.requests_fulfilled
      assert_equal 0, result.metrics.feedback_provided
      assert_equal 0, result.metrics.provided_by_request
    end
  end

  context "historical attribution" do
    should "infer proactive feedback from one unambiguous enrollment window" do
      feedback(person: @first, cycle_id: nil, recorded_at: 2.days.ago)

      assert_equal 1, result.metrics.feedback_provided
      assert_equal 1, result.metrics.provided_unsolicited
    end

    should "exclude legacy feedback when overlapping cycle windows are ambiguous" do
      overlapping = create(:assessment_cycle, :closed,
        tenant: @tenant, framework_id: @framework_id,
        opened_at: 20.days.ago, closed_at: 2.days.ago)
      create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: overlapping, person_id: @first.id,
        role_id: @role.role_id, level_ordinal: 2, enrolled_at: 15.days.ago)
      feedback(person: @first, cycle_id: nil, recorded_at: 5.days.ago)

      assert_equal 0, result.metrics.feedback_provided
    end

    should "attribute a historical late response to its request cycle" do
      closed_cycle = create(:assessment_cycle, :closed,
        tenant: @tenant, framework_id: SecureRandom.uuid_v7,
        opened_at: 10.days.ago, closed_at: 2.days.ago)
      create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: closed_cycle, person_id: @first.id,
        role_id: @role.role_id, level_ordinal: 2, enrolled_at: 10.days.ago)
      item = feedback(person: @first, cycle_id: nil,
        framework_id: closed_cycle.framework_id, recorded_at: 1.day.ago)
      request(person: @first, cycle_id: nil, status: "responded",
        framework_id: closed_cycle.framework_id, requested_at: 5.days.ago,
        evidence_id: item.id)

      report = Reporting::EvidenceCoverage.new(cycle: closed_cycle).call
      assert_equal 1, report.metrics.feedback_provided
      assert_equal 1, report.metrics.provided_by_request
      assert_equal 1, report.metrics.requests_fulfilled
    end

    should "not infer feedback recorded after close without a cycle request" do
      closed_cycle = create(:assessment_cycle, :closed,
        tenant: @tenant, framework_id: SecureRandom.uuid_v7,
        opened_at: 10.days.ago, closed_at: 2.days.ago)
      create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: closed_cycle, person_id: @first.id,
        role_id: @role.role_id, level_ordinal: 2, enrolled_at: 10.days.ago)
      feedback(person: @first, cycle_id: nil,
        framework_id: closed_cycle.framework_id, recorded_at: 1.day.ago)

      report = Reporting::EvidenceCoverage.new(cycle: closed_cycle).call
      assert_equal 0, report.metrics.feedback_provided
    end
  end

  private

  def result
    Reporting::EvidenceCoverage.new(cycle: @cycle).call
  end

  def enroll(person)
    create(:assessment_cycle_enrollment,
      tenant: @tenant, cycle: @cycle, person_id: person.id,
      role_id: @role.role_id, level_ordinal: 2, enrolled_at: 10.days.ago)
  end

  def feedback(person:, cycle_id: @cycle.cycle_id, framework_id: @framework_id,
               status: "active", recorded_at: Time.current, source: "self",
               feedback_direction: nil, external_reference: {}, author: @peer)
    create(:evidence_item, with_link: false,
      tenant: @tenant, author: author, person_id: person.id,
      framework_id: framework_id, cycle_id: cycle_id,
      source: source, feedback_direction: feedback_direction,
      link_status: status, recorded_at: recorded_at).tap do |item|
      item.update_columns(external_reference: external_reference) if external_reference.present?
    end
  end

  def request(person:, cycle_id: @cycle.cycle_id, framework_id: @framework_id,
              status:, requested_at: Time.current, evidence_id: nil)
    create(:evidence_request,
      tenant: @tenant, requester: @manager, requestee: @peer,
      person_id: person.id, framework_id: framework_id, cycle_id: cycle_id,
      status: status, requested_at: requested_at, evidence_id: evidence_id)
  end
end
