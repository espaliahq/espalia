# frozen_string_literal: true

# Returns one assessment's top-level structure — the framework it's
# against (full {Mcp::FrameworkSerializer} payload) plus an overlay of
# assignment-specific metadata (role / level the assessee is at, the
# currently open cycle, participant status in that cycle).
#
# Read-only; scoped by AssessmentPolicy#show?
# (owns_assessment? || manages_assessee?).
#
# The framework payload is a strict subset of this payload's `framework:`
# subtree — same keys, same nesting — so an LLM that learned the
# `frameworks_get` schema needs zero new schema knowledge to consume
# this. The overlay also carries `scoring:` — the assessment's score on
# the level-independent scale (ADR-21) plus a per-category roll-up, shaped
# by {Assessments::ScoreSummary} from the same builder the web renders, so
# an agent reads the number the person sees.
#
# `as_role_id` / `as_level_ordinal` read the same ratings against another role
# or level of the framework (a lens, ADR-22). The score then says so in
# `scoring.lens` (`home: false`), and each capability in the framework
# subtree carries `in_role: { home:, lens: }`, so a number read against PM3 is
# never mistaken for the assessment of record.
class Operations::Assessments::Get < Operations::Base
  include Operations::Assessments::ReadLens

  description "Fetch one assessment's framework structure, the assessee's current role/level/cycle status, and their score on the level-independent scale (100 = meeting their current level in full) with a per-category breakdown. Each score carries the scale's own meaning, its parts and the framework's thresholds; a score the screen withholds for lack of coverage reports scored: false rather than a number. Pass as_role_id and/or as_level_ordinal to read the same ratings against another role or level (a lens): scoring.lens.home is then false and it is not the assessment of record, and each capability's in_role says whether the record's role and the lens role read it."
  category :read
  approval :none

  parameter :assignment_id, String, required: true
  # Another role in the framework to read against; blank = the home role.
  parameter :as_role_id, String
  # A level of that role to read against; blank = the home level, or the
  # lens role's level nearest it.
  parameter :as_level_ordinal, Integer

  def policy_check
    authorize assignment, :show?
  end

  # @return [Hash] same payload as {Operations::Frameworks::Get} under
  #   `:framework`, plus `:assignment` (role + level + person identity),
  #   `:current_cycle` (id, name, status, planned_end_at) or nil, and
  #   `:scoring` (scale, score, state, components, thresholds, blocked
  #   capabilities, per-category roll-up).
  def perform
    {
      framework: with_in_role(Mcp::FrameworkSerializer.framework(assignment.framework)),
      assignment: assignment_payload,
      current_cycle: cycle_payload(assignment.current_open_cycle),
      scoring: score_summary.overall
    }
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  # The viewer's own perspective, resolved exactly as the web resolves it
  # (assessments.md) — the assessee must not read the manager's ratings
  # through the score until alignment starts.
  def score_summary
    @score_summary ||= Assessments::ScoreSummary.new(assignment: assignment, context: viewer_context, lens: read_lens)
  end

  # Overlays `in_role` on each capability of the framework subtree — an
  # overlay, so the subtree stays a superset of `frameworks_get`.
  def with_in_role(framework)
    return framework unless read_lens

    framework.merge(categories: framework[:categories].map do |category|
      category.merge(capabilities: category[:capabilities].map { |cap| cap.merge(in_role: in_role(cap[:stable_id])) })
    end)
  end

  def assignment_payload
    {
      id: assignment.id,
      # role / level are optional belongs_to (the FrameworkState rows
      # can be archived in a draft); safe-nav so the payload key set
      # stays stable even when the linked rows are gone.
      role: role_payload(assignment.role),
      level: level_payload(assignment.level),
      assessee: { id: assignment.person_id }
    }
  end

  def role_payload(role)
    role && { id: role.role_id, code: role.code, name: role.name }
  end

  def level_payload(level)
    level && { id: level.level_id, ordinal: level.ordinal, title: level.title }
  end

  def cycle_payload(cycle)
    return nil unless cycle

    {
      id: cycle.cycle_id,
      name: cycle.name,
      status: cycle.status,
      planned_end_at: cycle.planned_end_at&.iso8601,
      participant_status: assignment.current_open_cycle_participation&.status
    }
  end
end
