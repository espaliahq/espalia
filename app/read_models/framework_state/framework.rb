# frozen_string_literal: true

# Projection read model for published framework state.
#
# Materialised from Framework aggregate events by
# {Frameworks::Projections::PublishedState}.
#
class FrameworkState::Framework < ApplicationRecord
  self.table_name = "framework_states"

  # Pundit policy lookup: use FrameworkPolicy (not FrameworkState::FrameworkPolicy)
  def self.policy_class
    FrameworkPolicy
  end

  acts_as_tenant :tenant

  include HasTypeId
  has_typeid :frm

  belongs_to :tenant
  has_many :role_families, class_name: "FrameworkState::RoleFamily",
           primary_key: :framework_id, foreign_key: :framework_id, inverse_of: :framework,
           dependent: :destroy
  has_many :capability_categories, class_name: "FrameworkState::CapabilityCategory",
           primary_key: :framework_id, foreign_key: :framework_id, inverse_of: :framework,
           dependent: :destroy
  has_many :suggested_edits, class_name: "FrameworkState::SuggestedEdit",
           primary_key: :framework_id, foreign_key: :framework_id,
           dependent: :destroy
  # ExplorerGraph is 1:1 with a framework — the JSON snapshot that powers
  # the Framework Explorer matrix. Cascades on Framework destroy so tenant
  # teardown leaves no dangling row blocking the tenant FK.
  has_one :explorer_graph, class_name: "FrameworkExplorerGraph",
          primary_key: :framework_id, foreign_key: :framework_id,
          dependent: :destroy

  validates :framework_id, presence: true
  validates :name, presence: true
  validates :overperformance_cap, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :deficit_threshold, numericality: { greater_than_or_equal_to: 0 }

  # Whether an unpublished draft is currently open on this framework.
  #
  # @return [Boolean]
  def draft? = draft_in_progress

  # The thresholds hash PersonDevelopment::Scoring's constructor takes —
  # one derivation for every engine the app builds (assessment matrix,
  # attainment report, calibration cohorts), so they can't drift.
  #
  # @return [Hash]
  def scoring_thresholds
    {
      mastery_threshold: mastery_threshold&.to_f,
      meeting_expectation_threshold: meeting_expectation_threshold&.to_f,
      underperforming_threshold: underperforming_threshold&.to_f,
      overperformance_cap: overperformance_cap,
      deficit_threshold: deficit_threshold&.to_f
    }
  end
end
