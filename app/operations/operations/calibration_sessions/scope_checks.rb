# frozen_string_literal: true

# Shared input validation for the calibration-session Operations.
#
# Everything a client can get wrong raises {Operations::Base::ParameterError}
# (→ -32602 over MCP), never a raw AR/PG error: UUIDs are format-checked
# before any query (Postgres raises on an invalid uuid cast), person ids
# must exist in the tenant, and population/participant adds are confined
# to the facilitator's org subtree (tenant-wide when the acting user is a
# tenant/global admin — admins hold tenant-wide assessment visibility, so
# the facilitator-only access model still holds).
module Operations::CalibrationSessions::ScopeChecks
  UUID_RE = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  private

  # @param name [Symbol] parameter name for the error message
  # @param value [String]
  # @raise [Operations::Base::ParameterError] when not a UUID
  def ensure_uuid!(name, value)
    return if value.is_a?(String) && value.match?(UUID_RE)

    raise Operations::Base::ParameterError, "#{name} must be a UUID, got #{value.inspect}"
  end

  # @param name [Symbol] parameter name for the error message
  # @param values [Array] list expected to contain UUID strings
  # @return [Array<String>] the validated list
  # @raise [Operations::Base::ParameterError]
  def ensure_uuid_list!(name, values)
    list = Array(values)
    list.each { |value| ensure_uuid!(name, value) }
    list
  end

  # @param name [Symbol] parameter name for the error message
  # @param ids [Array<String>] person ids that must all exist in the tenant
  # @raise [Operations::Base::ParameterError] naming any missing ids
  def ensure_people_exist!(name, ids)
    return if ids.empty?

    missing = ids.uniq - Person.where(id: ids.uniq).pluck(:id)
    return if missing.empty?

    raise Operations::Base::ParameterError, "#{name} contains unknown people: #{missing.join(', ')}"
  end

  # Confines person ids to the facilitator's org subtree. Skipped for
  # tenant/global admin actors (tenant-wide scope).
  #
  # @param ids [Array<String>]
  # @param facilitator [Person]
  # @raise [Operations::Base::ParameterError] naming out-of-scope ids
  def ensure_within_facilitator_scope!(ids, facilitator)
    return if ids.empty?
    return if admin_actor?

    in_scope = facilitator.all_reports.where(id: ids.uniq).pluck(:id)
    out_of_scope = ids.uniq - in_scope
    return if out_of_scope.empty?

    raise Operations::Base::ParameterError,
          "not in the facilitator's org: #{out_of_scope.join(', ')}"
  end

  # @return [Boolean] whether the acting user is a tenant or global admin
  def admin_actor?
    context.user&.global_admin? || context.tenant_user&.admin? || false
  end

  # @return [CalibrationSession]
  # @raise [ActiveRecord::RecordNotFound]
  def session
    @session ||= begin
      ensure_uuid!(:session_id, params[:session_id])
      CalibrationSession.find(params[:session_id])
    end
  end

  # The session's facilitator Person — the anchor for subtree scoping.
  #
  # @return [Person]
  # @raise [Operations::Base::ParameterError] when the person row is gone
  def session_facilitator
    @session_facilitator ||= Person.find_by(id: session.facilitator_id) ||
      raise(Operations::Base::ParameterError,
            "session facilitator no longer exists: #{session.facilitator_id}")
  end

  # @return [AssessmentCycles::CalibrationCommandHandler]
  def command_handler
    @command_handler ||= AssessmentCycles::CalibrationCommandHandler.new
  end
end
