# frozen_string_literal: true

# One link of a stated succession: the successor carries on from the
# predecessor. A split writes one row per successor, a merge one per
# predecessor, all sharing the succession id.
#
# Projected by {OrgGraph::Projections::Structure}.
#
class OrgUnitSuccession < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :predecessor, class_name: "OrgUnit", inverse_of: :successor_links
  belongs_to :successor, class_name: "OrgUnit", inverse_of: :predecessor_links
end
