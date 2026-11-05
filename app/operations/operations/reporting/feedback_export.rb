# frozen_string_literal: true

# Every piece of feedback in an assessment cycle, one row each, for People &
# Culture's monthly reporting. Shared by the tenant-admin CSV download and
# the MCP tool, so both list the same rows in the same columns.
#
# Unlike the cycle's coverage report this carries names, emails and the
# feedback itself, so it is tenant-admin only and refused outright while an
# admin is viewing as someone else — even though it writes nothing.
#
# Returns plain hashes and strings: MCP serialises the result to JSON, and
# the web controller encodes `columns` + `rows` as CSV.
class Operations::Reporting::FeedbackExport < Operations::Base
  description "Export every piece of feedback / evidence in an assessment cycle, one row each, " \
              "for monthly reporting (tenant admins only): recipient and provider with their roles, " \
              "direction, requested or proactive (a GrowthOS request), where it was given (origin) and the request " \
              "it answered there, type, title, the feedback text, the behaviours it applies to, and status. " \
              "The rows match the feedback the cycle's coverage report counts as provided; include_withdrawn " \
              "adds the withdrawn items it reports separately. Pass month (YYYY-MM) to narrow to feedback " \
              "recorded in one calendar month. The response carries every row's full text, " \
              "so a month is far smaller than a whole cycle; for counts alone use reporting_evidence_coverage."
  category :read
  approval :none

  # The export's columns in order: the CSV header, the JSON `columns` list and
  # each row's keys all come from here.
  COLUMNS = {
    cycle: "Cycle",
    recorded_at: "Recorded at",
    recipient: "Recipient",
    recipient_email: "Recipient email",
    recipient_role: "Recipient role",
    recipient_level: "Recipient level",
    recipient_manager: "Recipient manager",
    provider: "Provider",
    provider_email: "Provider email",
    provider_role: "Provider role",
    direction: "Direction",
    requested: "Requested or proactive",
    requested_by: "Requested by",
    requested_at: "Requested at",
    type: "Type",
    title: "Title",
    feedback: "Feedback",
    applies_to: "Applies to",
    status: "Status",
    withdrawn_at: "Withdrawn at",
    reference_link: "Reference link",
    origin: "Origin",
    origin_request: "Origin request"
  }.freeze

  parameter :cycle_id, String, required: true, allow_blank: false,
    schema: Operations::Reporting::CyclesList::CYCLE_ID_SCHEMA
  parameter :month, String, required: false, allow_blank: false, schema: {
    pattern: ::Reporting::CycleMonth::JSON_SCHEMA_PATTERN,
    description: "Calendar month within the cycle, YYYY-MM. Omit for the whole cycle."
  }
  parameter :include_withdrawn, :boolean, required: false

  # Tenant admins with a linked Person (`TenantPolicy#export_feedback?`),
  # never while impersonating.
  #
  # @raise [Pundit::NotAuthorizedError] when the caller may not export, or is impersonating
  # @raise [ActiveRecord::RecordNotFound] when the cycle doesn't exist in the tenant
  def policy_check
    if AuditMetadata.current[:impersonation_active]
      raise Pundit::NotAuthorizedError, "Feedback can't be exported while viewing as another user."
    end

    authorize ActsAsTenant.current_tenant, :export_feedback?, policy_class: TenantPolicy
    cycle
  end

  # @return [Hash] { cycle:, period:, include_withdrawn:, columns:, rows: }
  def perform
    month = resolve_month
    rows = ::Reporting::FeedbackExport.new(
      cycle: cycle, period: month&.range, include_withdrawn: include_withdrawn?
    ).call
    log_export(month, rows.size)

    {
      cycle: { id: cycle.cycle_id, name: cycle.name },
      period: period_payload(month),
      include_withdrawn: include_withdrawn?,
      columns: COLUMNS.map { |key, label| { key: key.to_s, label: label } },
      rows: rows.map { |row| row.slice(*COLUMNS.keys) }
    }
  end

  private

  def cycle
    @cycle ||= AssessmentCycle.find_by!(cycle_id: params[:cycle_id])
  end

  def include_withdrawn?
    params[:include_withdrawn] == true
  end

  # The requested month, or nil for the whole cycle. A malformed key or a
  # month the cycle never spanned is the caller's mistake (-32602 over MCP).
  def resolve_month
    key = params[:month]
    return nil if key.nil?

    unless ::Reporting::CycleMonth.valid_key?(key)
      raise ParameterError, "month must be formatted YYYY-MM, got #{key.inspect}"
    end

    months = ::Reporting::CycleMonth.available_for(cycle)
    ::Reporting::CycleMonth.find_in(cycle, key, months: months) ||
      raise(ParameterError,
            "month #{key} is outside the cycle's lifespan (#{months.last.key} to #{months.first.key})")
  end

  def period_payload(month)
    return nil unless month

    {
      month: month.key,
      label: month.label,
      starts_at: month.range.begin.iso8601,
      ends_at: month.range.end.iso8601
    }
  end

  def log_export(month, row_count)
    Rails.logger.info(
      "[feedback_export] actor_person_id=#{context.person&.id} cycle_id=#{cycle.cycle_id} " \
      "month=#{month&.key || 'all'} include_withdrawn=#{include_withdrawn?} rows=#{row_count}"
    )
  end
end
