# frozen_string_literal: true

# Projection read model for suggestion discussion-thread comments.
#
# Materialised from SuggestionCommented / SuggestionCommentEdited /
# SuggestionCommentDeleted by {Frameworks::Projections::SuggestionThread}
# (the table's single writer). The PK is the event-carried comment_id, so
# `reset!` + replay reproduces the same externally-addressable ids.
#
# Threading mirrors {PersonDevelopmentComment}: a reply may target any
# non-deleted comment on the same suggestion (unbounded depth in data);
# display is flat with one indent level. Soft-delete keeps deleted rows
# (`status: "deleted"`) so reply chains stay coherent.
#
class FrameworkState::SuggestionComment < ApplicationRecord
  self.table_name = "framework_suggestion_comments"

  STATUSES = %w[active deleted].freeze

  acts_as_tenant :tenant
  belongs_to :tenant

  belongs_to :author, class_name: "Person", foreign_key: :author_id, inverse_of: false, optional: false
  belongs_to :parent, class_name: "FrameworkState::SuggestionComment",
             foreign_key: :parent_id, inverse_of: :replies, optional: true
  has_many :replies, class_name: "FrameworkState::SuggestionComment",
           foreign_key: :parent_id, inverse_of: :parent, dependent: :restrict_with_exception

  validates :framework_id, presence: true
  validates :suggestion_id, presence: true
  validates :body, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :posted_at, presence: true

  scope :active, -> { where(status: "active") }
  scope :for_suggestion, ->(suggestion_id) { where(suggestion_id: suggestion_id) }
  scope :for_framework, ->(framework_id) { where(framework_id: framework_id) }
  scope :top_level, -> { where(parent_id: nil) }
  scope :chronological, -> { order(:posted_at) }

  # Whether this comment has been soft-deleted.
  #
  # @return [Boolean]
  def deleted?
    status == "deleted"
  end
end
