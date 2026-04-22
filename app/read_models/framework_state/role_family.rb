# frozen_string_literal: true

# Projection read model for role families within a published framework.
#
# Materialised from Framework aggregate events by
# {Frameworks::Projections::PublishedState}.
#
class FrameworkState::RoleFamily < ApplicationRecord
  self.table_name = "framework_role_families"

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :framework, class_name: "FrameworkState::Framework",
             primary_key: :framework_id, foreign_key: :framework_id, inverse_of: :role_families,
             optional: true
  has_many :roles, class_name: "FrameworkState::Role",
           primary_key: :role_family_id, foreign_key: :role_family_id, inverse_of: :role_family,
           dependent: :destroy

  validates :framework_id, presence: true
  validates :role_family_id, presence: true
  validates :name, presence: true

  # `department` is not event-sourced — it is written directly to this read
  # model after publish (see seed_framework.rake). Rebuild the explorer
  # graph snapshot when it changes so view-mode rendering stays fresh.
  # Event-sourced fields like `name` reach the snapshot via the aggregate
  # on the normal write path, so no callback is needed for them here.
  after_update_commit :rebuild_explorer_graph, if: :saved_change_to_department?

  private

  def rebuild_explorer_graph
    Frameworks::ExplorerGraph.rebuild(framework_id)
  end
end
