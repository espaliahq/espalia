# frozen_string_literal: true

# Projection read model for published framework state.
#
# Materialised from Framework aggregate events by
# {Frameworks::Projections::PublishedState}.
#
class FrameworkState::Framework < ApplicationRecord
  self.table_name = "framework_states"

  acts_as_tenant :tenant
  has_prefix_id :frm

  belongs_to :tenant

  validates :framework_id, presence: true
  validates :name, presence: true
end
