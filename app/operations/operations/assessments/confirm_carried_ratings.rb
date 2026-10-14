# frozen_string_literal: true

# Confirms ratings carried forward from the last cycle, unchanged, for this
# cycle — the same as re-picking each value on its pill (#480).
#
# Each cell is confirmed through {RateSelf} / {RateAsManager} with their
# explicit `confirm`, so the policy, frozen-cell and lens checks are the same
# code a single confirm runs. The explicit flag matters: re-sending a value
# that is already human-owned would otherwise CLEAR it (the untoggle), and a
# stale list or a repeated cell would do exactly that. Cells that fail any
# check are skipped with the reason, never fatal to the rest.
#
# Write — :mcp_client approval, despite touching many records: every effect
# is one an allowed :mcp_client rating call already has, no value changes
# (only who vouches for it this cycle), and it is limited to the caller's
# own side of their own or their report's assessment.
class Operations::Assessments::ConfirmCarriedRatings < Operations::Base
  CELLS_SCHEMA = {
    "type" => "array",
    "minItems" => 1,
    "items" => {
      "type" => "object",
      "properties" => {
        "capability_stable_id" => { "type" => "string" },
        "level_ordinal" => { "type" => "integer" }
      },
      "required" => %w[capability_stable_id level_ordinal],
      "additionalProperties" => false
    }
  }.freeze

  DELEGATES = {
    "self" => Operations::Assessments::RateSelf,
    "manager" => Operations::Assessments::RateAsManager
  }.freeze

  description "Confirm ratings carried forward from the last cycle, unchanged, as this cycle's rating — " \
              "the same as re-picking each value. perspective self confirms your own ratings, manager " \
              "the manager ratings you give. Only cells whose value on that side is still carried are " \
              "confirmed; the rest are listed under skipped with the reason. To change a value use " \
              "assessments_rate_self or assessments_rate_as_manager instead."
  category :write
  approval :mcp_client

  parameter :assignment_id, String, required: true
  parameter :perspective,   String, required: true, allowed: DELEGATES.keys
  parameter :cells,         Array,  required: true, schema: CELLS_SCHEMA

  def policy_check
    authorize assignment, perspective == "self" ? :create_self_rating? : :create_manager_rating?
  end

  # @return [Hash] `{ cycle_id, perspective, confirmed: [cell], skipped: [cell + reason] }`
  def perform
    cycle = assignment.current_open_cycle
    raise Operations::Base::ParameterError, "no open assessment cycle" if cycle.nil?

    rows = existing_rows(cycle.cycle_id)
    result = { cycle_id: cycle.cycle_id, perspective: perspective, confirmed: [], skipped: [] }
    cells.each do |cell|
      reason = confirm(cell, rows[[ cell[:capability_stable_id], cell[:level_ordinal] ]])
      reason ? result[:skipped] << cell.merge(reason: reason) : result[:confirmed] << cell
    end
    result
  end

  private

  def perspective = params[:perspective]

  # @return [String, nil] why the cell was skipped, nil when confirmed
  def confirm(cell, row)
    frequency, carried = side_of(row)
    return "not carried" unless frequency.present? && carried

    operation = DELEGATES.fetch(perspective).new(context: context, params: {
      assignment_id: assignment.id, capability_stable_id: cell[:capability_stable_id],
      level_ordinal: cell[:level_ordinal], frequency: frequency, confirm: true
    })
    operation.call
    operation.changed? ? nil : "not carried"
  rescue Pundit::NotAuthorizedError, Operations::Base::ParameterError => e
    e.message
  end

  def side_of(row)
    return [ nil, false ] unless row

    if perspective == "self"
      [ row.self_rated_frequency, row.self_rating_carried? ]
    else
      [ row.manager_rated_frequency, row.manager_rating_carried? ]
    end
  end

  # The named cells' rows — read across roles, since each cell is named.
  def existing_rows(cycle_id)
    AssessmentLevelRating.across_all_roles
      .where(cycle_id: cycle_id, person_id: assignment.person_id, framework_id: assignment.framework_id,
             capability_stable_id: cells.map { |cell| cell[:capability_stable_id] }.uniq)
      .index_by { |row| [ row.capability_stable_id, row.level_ordinal ] }
  end

  # Cells as symbol-keyed hashes; a malformed entry is the client's mistake
  # (-32602), never an internal error (mcp-server.md, Lesson 13).
  def cells
    @cells ||= params[:cells].map do |raw|
      unless raw.is_a?(Hash) || raw.is_a?(ActionController::Parameters)
        raise Operations::Base::ParameterError, "each cell must be an object"
      end

      cell = raw.to_h.transform_keys(&:to_s)
      unknown = cell.keys - %w[capability_stable_id level_ordinal]
      raise Operations::Base::ParameterError, "unknown cell keys: #{unknown.join(', ')}" if unknown.any?

      stable_id = cell["capability_stable_id"]
      ordinal = Integer(cell["level_ordinal"], exception: false)
      if stable_id.blank? || ordinal.nil?
        raise Operations::Base::ParameterError, "each cell needs capability_stable_id and an integer level_ordinal"
      end

      { capability_stable_id: stable_id, level_ordinal: ordinal }
    end.uniq
  end

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end
end
