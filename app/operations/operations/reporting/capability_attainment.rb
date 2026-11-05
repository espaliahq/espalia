# frozen_string_literal: true

# Aggregate capability attainment for an assessment cycle, shared by the web
# heatmap and the MCP server. Per role and role family: the share of people at
# or above their assessed level on each bound capability (with assessed
# coverage), plus the share passing each category gate.
#
# Scoped to the caller's org subtree (admins/HR see the whole cycle).
# Small-cohort suppression applies only to viewers who cannot open their
# scope's individual assessments (AssessmentCyclePolicy#attainment_unsuppressed?
# — currently every attainment viewer qualifies as unsuppressed, since the
# manager chain has full individual view access). Returns aggregates only,
# never individual ratings.
class Operations::Reporting::CapabilityAttainment < Operations::Base
  description "Aggregate capability attainment for an assessment cycle across the caller's " \
              "org subtree (admins see the whole cycle): per role and role family, the share " \
              "of people at or above their assessed level on each capability with assessed " \
              "coverage, plus the share passing each category gate. Returns aggregates only " \
              "— never individual ratings."
  category :read
  approval :none

  # URL-ish param → PersonDevelopment::Scoring perspective (mirrors the web
  # controller's mapping).
  PERSPECTIVES = {
    "effective" => :effective,
    "self" => :self_only,
    "manager" => :manager_only,
    "aligned" => :aligned_only
  }.freeze

  parameter :cycle_id, String, required: true,
    schema: Operations::Reporting::CyclesList::CYCLE_ID_SCHEMA
  parameter :perspective, String, required: false, allowed: PERSPECTIVES.keys
  parameter :scope, String, required: false, allowed: %w[mine all]

  def policy_check
    authorize cycle, :attainment?
  end

  def perform
    result = ::Reporting::CapabilityAttainment.new(
      cycle: cycle,
      scope_person_ids: scope_person_ids,
      perspective: PERSPECTIVES.fetch(params[:perspective] || "effective"),
      suppress_small_groups: !policy.attainment_unsuppressed?
    ).call

    serialize(result)
  end

  private

  def cycle
    @cycle ||= AssessmentCycle.find_by!(cycle_id: params[:cycle_id])
  end

  def policy
    @policy ||= AssessmentCyclePolicy.new(context, cycle)
  end

  # nil = whole cycle; otherwise the caller's org subtree. Non-admins are
  # always scoped; admins/HR see the whole cycle unless they pass scope: "mine".
  def scope_person_ids
    return context.person&.all_reports&.pluck(:id) || [] if scope_to_subtree?

    nil
  end

  def scope_to_subtree?
    !policy.cohort_full_access? || params[:scope] == "mine"
  end

  def serialize(result)
    {
      cycle: { id: result.cycle.cycle_id, name: result.cycle.name },
      perspective: result.perspective.to_s,
      total_people: result.total_people,
      suppression_floor: result.suppression_floor,
      categories: result.categories.map { |category| { id: category.category_id, name: category.name } },
      capabilities: result.capabilities.map do |capability|
        { stable_id: capability.stable_id, name: capability.name, category_id: capability.category_id }
      end,
      roles: result.roles.map { |group| group_payload(group) },
      families: result.families.map { |group| group_payload(group) }
    }
  end

  def group_payload(group)
    {
      key: group.key,
      label: group.label,
      family_key: group.family_key,
      n_people: group.n_people,
      cells: group.cells.transform_values { |cell| cell_payload(cell) },
      category_cells: group.category_cells.transform_values { |cell| category_cell_payload(cell) }
    }
  end

  def cell_payload(cell)
    {
      at_or_above_pct: cell.at_or_above_pct,
      below: cell.below, at: cell.at, above: cell.above,
      n_assessed: cell.n_assessed, n_in_group: cell.n_in_group,
      suppressed: cell.suppressed
    }
  end

  def category_cell_payload(cell)
    {
      pass_pct: cell.pass_pct, pass_count: cell.pass_count,
      n_in_group: cell.n_in_group, suppressed: cell.suppressed
    }
  end
end
