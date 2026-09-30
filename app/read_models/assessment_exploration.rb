# frozen_string_literal: true

# Projection read model: a declared exploration of another role or level
# (ADR-22) — "we've agreed to explore PM3".
#
# An intent fact, not a rating scope: the lens reads the person's ratings
# against the target, and this row only says the exploration was declared,
# by whom, and what came of it. Not tied to a cycle, and never read by a
# cohort surface.
#
# The primary key is the event-carried `exploration_id`, so a rebuild
# reproduces the id an MCP client or a URL holds. Owned exclusively by
# {PersonDevelopment::Projections::CurrentAssessment}.
class AssessmentExploration < ApplicationRecord
  STATUSES = %w[open closed].freeze
  OUTCOMES = PersonDevelopment::Aggregate::EXPLORATION_OUTCOMES

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :target_role, class_name: "FrameworkState::Role",
             primary_key: :role_id, foreign_key: :target_role_id, inverse_of: false, optional: true
  belongs_to :started_by, class_name: "Person", foreign_key: :started_by_id, inverse_of: false, optional: true
  belongs_to :closed_by, class_name: "Person", foreign_key: :closed_by_id, inverse_of: false, optional: true

  validates :person_id, :framework_id, :target_role_id, :target_level_id, :started_at, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true

  scope :open, -> { where(status: "open") }
  scope :for_assignment, ->(assignment) { where(person_id: assignment.person_id, framework_id: assignment.framework_id) }

  # @return [Boolean]
  def open? = status == "open"

  # @return [String, nil] e.g. "PM3"; nil when the role is gone
  def code
    target_role && "#{target_role.code}#{target_level_ordinal}"
  end

  # @return [String, nil] e.g. "Product Manager · PM3"
  def label
    target_role && "#{target_role.name} · #{code}"
  end
end
