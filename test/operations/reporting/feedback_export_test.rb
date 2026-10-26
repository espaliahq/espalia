# frozen_string_literal: true

require "test_helper"

class Operations::Reporting::FeedbackExportTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7
    @role = create(:framework_role, name: "Software Engineer", code: "E")
    @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, code: "E2", title: "Engineer II")
    category = create(:framework_capability_category, framework_id: @framework_id)
    @capability = create(:framework_capability, category_id: category.category_id, name: "Strategic Thinking")
    @cycle = create(:assessment_cycle,
      tenant: @tenant, name: "Q3 2026", framework_id: @framework_id, opened_at: 10.days.ago)

    @manager = create(:person, tenant: @tenant, name: "Morgan Manager", email: "morgan@example.com")
    @peer = create(:person, tenant: @tenant, name: "Pat Peer", email: "pat@example.com")
    @first = create(:person, tenant: @tenant, name: "Fran First", email: "fran@example.com", manager: @manager)
    @second = create(:person, tenant: @tenant, name: "Sam Second", email: "sam@example.com", manager: @manager)
    [ @first, @second ].each { |person| enroll(person) }
    create(:person_framework_assignment,
      tenant: @tenant, person_id: @peer.id, framework_id: @framework_id,
      role_id: @role.role_id, level_id: @level.level_id)

    @admin_user = create(:user)
    @admin = create(:person, tenant: @tenant, email: @admin_user.email, name: "Ada Admin")
    @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, person: @admin, role: :admin)
    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: @admin)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  context "row shape" do
    setup do
      @item = feedback(person: @first, content: "Great roadmap call.", title: "Roadmap",
        evidence_type: "other", custom_type_label: "Offsite", source: "peer",
        feedback_direction: "peer_to_peer", recorded_at: Time.zone.parse("2026-09-20 09:30:00"),
        external_reference: { system: "notion", url: "https://notion.so/doc" })
      EvidenceLink.create!(
        tenant: @tenant, evidence_item: @item, person_id: @first.id, framework_id: @framework_id,
        capability_stable_id: @capability.stable_id, level_ordinal: 2, valence: "demonstrated",
        linked_by_id: @peer.id, linked_at: @item.recorded_at)
      request(person: @first, evidence_id: @item.id, status: "responded",
        requested_at: Time.zone.parse("2026-09-19 08:00:00"))
      @cycle.update!(opened_at: Time.zone.parse("2026-09-01"))
      @first_enrollment.update!(enrolled_at: Time.zone.parse("2026-09-01"))
    end

    should "list one row of plain strings per item, in the declared column order" do
      result = call_op
      row = result[:rows].sole

      assert_equal Operations::Reporting::FeedbackExport::COLUMNS.keys, row.keys
      assert_equal Operations::Reporting::FeedbackExport::COLUMNS.keys.map(&:to_s),
        result[:columns].pluck(:key)
      assert_equal "Recorded at", result[:columns].second[:label]
      assert(row.values.all? { |value| value.nil? || value.is_a?(String) })
      assert_equal JSON.parse(JSON.generate(result)).dig("rows", 0, "feedback"), "Great roadmap call."
    end

    should "describe the recipient, provider, request and behaviours" do
      row = call_op[:rows].sole

      assert_equal "Q3 2026", row[:cycle]
      assert_equal "2026-09-20T09:30:00Z", row[:recorded_at]
      assert_equal "Fran First", row[:recipient]
      assert_equal "fran@example.com", row[:recipient_email]
      assert_equal "Software Engineer", row[:recipient_role]
      assert_equal "Engineer II", row[:recipient_level]
      assert_equal "Morgan Manager", row[:recipient_manager]
      assert_equal "Pat Peer", row[:provider]
      assert_equal "pat@example.com", row[:provider_email]
      assert_equal "Software Engineer", row[:provider_role]
      assert_equal "Peer → peer", row[:direction]
      assert_equal "Requested", row[:requested]
      assert_equal "Morgan Manager", row[:requested_by]
      assert_equal "2026-09-19T08:00:00Z", row[:requested_at]
      assert_equal "Offsite", row[:type]
      assert_equal "Roadmap", row[:title]
      assert_equal "Great roadmap call.", row[:feedback]
      assert_equal "Strategic Thinking · E2 · Demonstrates", row[:applies_to]
      assert_equal "Active", row[:status]
      assert_nil row[:withdrawn_at]
      assert_equal "https://notion.so/doc", row[:reference_link]
    end

    should "fall back to the legacy direction and mark proactive feedback" do
      feedback(person: @second, source: "peer", feedback_direction: nil, content: "Legacy note.")
      row = call_op[:rows].find { |candidate| candidate[:feedback] == "Legacy note." }

      assert_equal "Peer → peer or report → manager (historical)", row[:direction]
      assert_equal "Proactive", row[:requested]
      assert_nil row[:requested_by]
      assert_equal "Project outcome", row[:type]
    end

    should "report what the recipient wrote as self feedback, though recorded as peer" do
      feedback(person: @second, author: @second, source: "peer", feedback_direction: "peer_to_peer",
        content: "My reflection.")
      row = call_op[:rows].find { |candidate| candidate[:feedback] == "My reflection." }

      assert_equal "Self", row[:direction]
    end
  end

  context "origin" do
    setup do
      @native = feedback(person: @first, content: "Native.")
      @slack = feedback(person: @first, content: "From Slack.", external_reference: { system: "slack" })
      @chip = peer_feedback(person: @second, content: "From Chip.", system: "chip",
        metadata: { request_context: "Q3 growth check-in" })
      @chip_plain = peer_feedback(person: @second, content: "Chip, unasked.", system: "chip")
      @unknown = peer_feedback(person: @second, content: "Elsewhere.", system: "hr_portal")
      @slack_peer = peer_feedback(person: @second, content: "Imported from a peer named slack.", system: "slack",
        metadata: { given_at: "2026-10-18T03:12:44Z" })
    end

    should "name where each item was given, GrowthOS for native ones and plain links" do
      rows = call_op[:rows].index_by { |row| row[:feedback] }

      assert_equal "GrowthOS", rows["Native."][:origin]
      assert_equal "GrowthOS", rows["From Slack."][:origin]
      assert_equal "Slack", rows["Imported from a peer named slack."][:origin]
      assert_equal "Chip", rows["From Chip."][:origin]
      assert_equal "Hr Portal", rows["Elsewhere."][:origin]
    end

    should "carry the request the item answered in its source system" do
      rows = call_op[:rows].index_by { |row| row[:feedback] }

      assert_equal "Q3 growth check-in", rows["From Chip."][:origin_request]
      assert_nil rows["Chip, unasked."][:origin_request]
      assert_nil rows["Native."][:origin_request]
    end

    should "leave Requested or proactive about GrowthOS requests only" do
      row = call_op[:rows].find { |candidate| candidate[:feedback] == "From Chip." }

      assert_equal "Proactive", row[:requested]
    end

    should "ignore a request context that is not text" do
      @chip_plain.update_columns(external_reference: { system: "chip", metadata: { request_context: { a: 1 } } })
      row = call_op[:rows].find { |candidate| candidate[:feedback] == "Chip, unasked." }

      assert_nil row[:origin_request]
    end

    should "list the origin columns after the reference link" do
      keys = Operations::Reporting::FeedbackExport::COLUMNS.keys

      assert_equal %i[reference_link origin origin_request], keys.last(3)
    end

    should "agree with the coverage report's origin split" do
      coverage = Reporting::EvidenceCoverage.new(cycle: @cycle).call.metrics.by_origin
      export = call_op[:rows].pluck(:origin).tally
      expected = coverage.reject { |_, count| count.zero? }
        .transform_keys { |key| Reporting::OriginLabels.peer_label(key) }

      assert_equal expected, export
    end
  end

  context "cycle attribution" do
    setup do
      feedback(person: @first, content: "explicit")
      inherited = feedback(person: @first, cycle_id: nil, content: "request-inherited", recorded_at: 1.day.ago)
      request(person: @first, evidence_id: inherited.id, status: "responded", requested_at: 2.days.ago)
      feedback(person: @second, cycle_id: nil, content: "window-inferred", recorded_at: 2.days.ago)
      feedback(person: @first, status: "withdrawn", content: "withdrawn")

      overlapping = create(:assessment_cycle, :closed,
        tenant: @tenant, framework_id: @framework_id, opened_at: 20.days.ago, closed_at: 2.days.ago)
      create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: overlapping, person_id: @first.id,
        role_id: @role.role_id, level_ordinal: 2, enrolled_at: 15.days.ago)
      feedback(person: @first, cycle_id: nil, content: "ambiguous", recorded_at: 5.days.ago)
      feedback(person: @first, cycle_id: overlapping.cycle_id, content: "other cycle")
    end

    should "list exactly the feedback the coverage report counts" do
      rows = call_op[:rows]
      coverage = Reporting::EvidenceCoverage.new(cycle: @cycle).call

      assert_equal coverage.metrics.feedback_provided, rows.size
      assert_equal %w[explicit request-inherited window-inferred].sort, rows.pluck(:feedback).sort
      assert_equal coverage.metrics.provided_by_request, rows.count { |row| row[:requested] == "Requested" }
    end

    should "add withdrawn feedback only when asked" do
      rows = call_op(include_withdrawn: true)[:rows]
      withdrawn = rows.find { |row| row[:feedback] == "withdrawn" }
      coverage = Reporting::EvidenceCoverage.new(cycle: @cycle).call

      assert_equal coverage.metrics.feedback_provided + coverage.metrics.feedback_withdrawn, rows.size
      assert_equal "Withdrawn", withdrawn[:status]
      assert_not_nil withdrawn[:withdrawn_at]
    end

    should "show the links a withdrawn item had once a migration removed them all" do
      orphan = feedback(person: @second, status: "withdrawn", content: "orphaned")
      EvidenceLink.create!(
        tenant: @tenant, evidence_item: orphan, person_id: @second.id, framework_id: @framework_id,
        capability_stable_id: @capability.stable_id, level_ordinal: 2,
        link_status: "removed", linked_by_id: @peer.id, linked_at: 1.day.ago, removed_at: Time.current)

      row = call_op(include_withdrawn: true)[:rows].find { |candidate| candidate[:feedback] == "orphaned" }
      assert_equal "Strategic Thinking · E2", row[:applies_to]
    end

    should "accept the boolean-ish string a web form submits" do
      assert_equal 4, call_op(include_withdrawn: "1")[:rows].size
    end
  end

  context "month filter" do
    setup do
      @this_month = Time.current.beginning_of_month
      @last_month = @this_month.prev_month
      @cycle.update!(opened_at: @last_month)
      [ @first_enrollment, @second_enrollment ].each { |enrollment| enrollment.update!(enrolled_at: @last_month) }
      feedback(person: @first, recorded_at: @last_month + 3.days, content: "last month")
      feedback(person: @first, recorded_at: @this_month + 2.hours, content: "this month")
    end

    should "narrow to feedback recorded in the month, matching the coverage report" do
      key = @this_month.strftime("%Y-%m")
      result = call_op(month: key)
      coverage = Reporting::EvidenceCoverage.new(cycle: @cycle, period: @this_month.all_month).call

      assert_equal [ "this month" ], result[:rows].pluck(:feedback)
      assert_equal coverage.metrics.feedback_provided, result[:rows].size
      assert_equal key, result.dig(:period, :month)
    end

    should "list the whole cycle oldest first without a month" do
      result = call_op

      assert_nil result[:period]
      assert_equal [ "last month", "this month" ], result[:rows].pluck(:feedback)
    end

    should "reject a month outside the cycle" do
      error = assert_raises(Operations::Base::ParameterError) { call_op(month: "2001-01") }
      assert_match "outside the cycle's lifespan", error.message
    end

    should "reject a malformed month" do
      assert_raises(Operations::Base::ParameterError) { call_op(month: "June") }
    end
  end

  context "authorization" do
    should "deny a member" do
      assert_denied(context_for(role: :member, person: create(:person, tenant: @tenant)))
    end

    should "deny a manager even with reports in the cycle" do
      user = create(:user, email: @manager.email)
      tenant_user = create(:tenant_user, tenant: @tenant, user: user, person: @manager, role: :member)

      assert_denied(AuthorizationContext.new(user: user, tenant_user: tenant_user, person: @manager))
    end

    should "deny a global admin with no person" do
      user = create(:user, global_admin: true)

      assert_denied(AuthorizationContext.new(user: user, tenant_user: nil, person: nil))
    end

    should "refuse an admin who is viewing as someone else" do
      error = AuditMetadata.with(acting_via: :web, actor_id: @first.id, impersonator_id: @admin.id,
                                 impersonation_active: true) do
        assert_raises(Pundit::NotAuthorizedError) { call_op }
      end

      assert_match "viewing as another user", error.message
    end

    should "404 an unknown cycle only after the policy passes" do
      assert_raises(ActiveRecord::RecordNotFound) do
        Operations::Reporting::FeedbackExport.call(context: @admin_ctx, params: { cycle_id: SecureRandom.uuid_v7 })
      end
    end
  end

  should "log one audit line per export" do
    feedback(person: @first)
    logged = []
    Rails.logger.stub(:info, ->(message = nil) { logged << message }) { call_op }

    line = logged.find { |message| message.to_s.start_with?("[feedback_export]") }
    assert_equal "[feedback_export] actor_person_id=#{@admin.id} cycle_id=#{@cycle.cycle_id} " \
                 "month=all include_withdrawn=false rows=1", line
  end

  private

  def call_op(**params)
    Operations::Reporting::FeedbackExport.call(
      context: @admin_ctx, params: { cycle_id: @cycle.cycle_id, **params }
    )
  end

  def assert_denied(context)
    assert_raises(Pundit::NotAuthorizedError) do
      Operations::Reporting::FeedbackExport.call(context: context, params: { cycle_id: @cycle.cycle_id })
    end
  end

  def context_for(role:, person:)
    user = create(:user, email: person.email)
    tenant_user = create(:tenant_user, tenant: @tenant, user: user, person: person, role: role)
    AuthorizationContext.new(user: user, tenant_user: tenant_user, person: person)
  end

  def enroll(person)
    enrollment = create(:assessment_cycle_enrollment,
      tenant: @tenant, cycle: @cycle, person_id: person.id, role_id: @role.role_id,
      level_id: @level.level_id, level_ordinal: 2, enrolled_at: 10.days.ago)
    instance_variable_set(person == @first ? :@first_enrollment : :@second_enrollment, enrollment)
  end

  def feedback(person:, cycle_id: @cycle.cycle_id, status: "active", recorded_at: Time.current, author: @peer,
               **attributes)
    create(:evidence_item, with_link: false,
      tenant: @tenant, author: author, person_id: person.id, framework_id: @framework_id,
      cycle_id: cycle_id, link_status: status, recorded_at: recorded_at,
      withdrawn_at: (Time.current if status == "withdrawn"), **attributes)
  end

  # Written straight to the column, as the importer's projection writes it.
  def peer_feedback(person:, system:, metadata: {}, **attributes)
    feedback(person: person, **attributes).tap do |item|
      item.update_columns(external_reference: { system: system, metadata: metadata })
    end
  end

  def request(person:, evidence_id:, status:, requested_at:)
    create(:evidence_request,
      tenant: @tenant, requester: @manager, requestee: @peer, person_id: person.id,
      framework_id: @framework_id, cycle_id: @cycle.cycle_id, status: status,
      requested_at: requested_at, evidence_id: evidence_id)
  end
end
