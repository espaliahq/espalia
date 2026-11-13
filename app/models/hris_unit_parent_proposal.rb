# frozen_string_literal: true

# A parent the HRIS sync has read for a mirrored unit and not yet written.
#
# The HRIS states no parent, so {Hris::LevelMirror} reads one from the unit's
# people. It moves the unit only when two syncs in a row give the same answer,
# so a person caught mid-transfer can't move a team. This row is the first of
# those two readings. The sync owns it; nothing projects it.
#
class HrisUnitParentProposal < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :tenant

  validates :unit_id, :parent_id, :first_seen_on, presence: true
end
