# frozen_string_literal: true

require "test_helper"

# Every MCP read, run over data a forgotten person took part in, must show
# them as a former member: never a blank name, an error or the erased name.
# A new read operation fails here until it is walked or exempted.
class ForgottenPersonAuditTest < ActiveSupport::TestCase
  ERASED_NAME = "Quinn Leaver"
  ERASED_EMAIL = "quinn.leaver@example.com"

  # Reads that cannot meet a forgotten person, with the reason.
  EXEMPT = {
    "frameworks_suggestion_get" => "names its author through people.name, as frameworks_recent_activity does here",
    "integrations_hris_field_preview" => "reads the live HRIS, which no longer holds a forgotten person"
  }.freeze

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @fx = build_role_lens_framework(tenant: @tenant)

    @lead_user = create(:user)
    @lead = create(:person, tenant: @tenant, name: "Morgan Lead", email: @lead_user.email)
    @lead_tu = create(:tenant_user, tenant: @tenant, user: @lead_user, person: @lead, role: :admin)
    @alex = create(:person, tenant: @tenant, name: "Alex Example", manager: @lead)
    @quinn = create(:person, tenant: @tenant, name: ERASED_NAME, email: ERASED_EMAIL, manager: @lead)
    create(:person, tenant: @tenant, name: "Riley Report", manager: @quinn)

    @assignment, @cycle_id = enrol_in_role_lens_framework(@alex, @fx, tenant: @tenant)
    quinn_level = @fx.e_levels.fetch(2).level_id
    pd.assign_to_framework(@quinn.id, @fx.framework_id, @fx.engineer.role_id, quinn_level)

    take_part_as_quinn
    forget_quinn
  end

  teardown { ActsAsTenant.current_tenant = nil }

  should "show a forgotten person as a former member in every read" do
    reads = Operations::Registry.all.select { |op| op.category == :read }
    unwalked = reads.map { |op| Operations::Registry.tool_name_for(op) } - params_by_tool.keys - EXEMPT.keys
    assert_empty unwalked, "walk these reads here, or exempt them with a reason"

    reached = reads.filter_map do |op|
      tool = Operations::Registry.tool_name_for(op)
      next if EXEMPT.key?(tool)

      output = op.call(context: lead_context, params: params_by_tool.fetch(tool)).as_json
      json = output.to_json
      assert_no_match(/#{ERASED_NAME}|#{Regexp.escape(ERASED_EMAIL)}/o, json, "#{tool} shows the erased identity")
      blank = blank_names(output)
      assert_empty blank, "#{tool} leaves a forgotten person without a name at #{blank.inspect}"
      tool if json.include?(Person::FORMER_MEMBER)
    end

    assert_includes reached, "assessments_evidence_list"
    assert_includes reached, "assessments_comments_list"
    assert_includes reached, "calibration_sessions_get"
    assert_includes reached, "reporting_cycle_cohort"
    assert_not_includes reached, "assessments_feedback_recipients", "a search for the stand-in offers them"
  end

  private

  def pd = PersonDevelopment::CommandHandler.new

  def lead_context = AuthorizationContext.new(user: @lead_user, tenant_user: @lead_tu, person: @lead)

  def take_part_as_quinn
    cell = { capability_stable_id: @fx.shared.stable_id, level_ordinal: 2 }
    @evidence_id = evidence_id = SecureRandom.uuid_v7
    pd.record_evidence(@alex.id, @fx.framework_id, evidence_id, **cell, source: "peer",
      evidence_type: "peer_feedback", content: "Paired on the incident review", author_id: @quinn.id,
      valence: "demonstrated")
    pd.post_comment(@alex.id, @fx.framework_id, SecureRandom.uuid_v7, commentable_type: "evidence_link",
      body: "Happy to add more", author_id: @quinn.id, evidence_id: evidence_id, **cell)
    pd.request_evidence(@alex.id, @fx.framework_id, SecureRandom.uuid_v7, requested_by_id: @lead.id,
      requestee_person_id: @quinn.id, **cell)
    pd.rate_self(@quinn.id, @fx.framework_id, @fx.shared.stable_id, level_ordinal: 2,
      frequency: "consistent", cycle_id: @cycle_id)

    @session_id = SecureRandom.uuid_v7
    Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
      AssessmentCycles::CalibrationCommandHandler.new.define_session(
        @session_id, @cycle_id, @fx.framework_id, "Engineering calibration", 1,
        facilitator_id: @lead.id, participant_ids: [ @quinn.id ], calibrant_person_ids: [ @alex.id ]
      )
    end
  end

  # The row as OrgGraph::Forgetting#erase_identifiers leaves it.
  def forget_quinn
    @quinn.update_columns(name: Person::FORMER_MEMBER, email: nil, external_id: nil, hris_raw_data: nil,
                          forgotten_at: Time.current)
  end

  def params_by_tool
    @params_by_tool ||= begin
      assessment = { assignment_id: @assignment.id }
      cell = { **assessment, capability_stable_id: @fx.shared.stable_id, level_ordinal: 2 }
      framework = { framework_id: @fx.framework_id }
      cycle = { cycle_id: @cycle_id }
      {
        "assessments_capability_get" => { **assessment, capability_id: @fx.shared.stable_id },
        "assessments_comments_list" => { **cell, evidence_id: @evidence_id },
        "assessments_evidence_list" => cell,
        "assessments_evidence_requests_list" => {},
        "assessments_evidence_suggestions_list" => assessment,
        "assessments_explorations_list" => assessment,
        "assessments_feedback_recipients" => { query: "former" },
        "assessments_feedback_to_place" => {},
        "assessments_get" => assessment,
        "assessments_mine" => {},
        "assessments_recent_activity" => {},
        "assessments_timeline" => assessment,
        "calibration_sessions_get" => { session_id: @session_id },
        "calibration_sessions_list" => cycle,
        "calibration_sessions_overview" => { session_id: @session_id },
        "frameworks_capability_get" => { **framework, capability_id: @fx.shared.stable_id },
        "frameworks_draft_changes" => framework,
        "frameworks_get" => framework,
        "frameworks_list" => {},
        "frameworks_recent_activity" => framework,
        "integrations_ai_model_status" => {},
        "integrations_feedback_exchange_status" => {},
        "integrations_hris_titles" => {},
        "reporting_capability_attainment" => cycle,
        "reporting_cycle_cohort" => { **cycle, mode: "full" },
        "reporting_cycles_list" => {},
        "reporting_evidence_coverage" => { **cycle, mode: "full" },
        "reporting_feedback_export" => cycle,
        "system_whoami" => {},
        "tenants_forgetting_dry_run" => {}
      }
    end
  end

  # Paths to a name beside the forgotten person's id that is blank.
  def blank_names(node, path = [])
    case node
    when Hash
      own = node.values.include?(@quinn.id) ? node.select { |key, value| key.to_s.end_with?("name") && value.blank? } : {}
      own.keys.map { |key| (path + [ key ]).join(".") } +
        node.flat_map { |key, value| blank_names(value, path + [ key ]) }
    when Array then node.each_with_index.flat_map { |value, i| blank_names(value, path + [ i ]) }
    else []
    end
  end
end
