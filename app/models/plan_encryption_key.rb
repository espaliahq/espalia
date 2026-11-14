# frozen_string_literal: true

# One key that encrypts a plan's shreddable fields: the plan's own key, or
# the key for one person within the plan. {PlanKeyStore} is the way in.
#
# A destroyed key keeps its row as a tombstone, with no key material, so a
# later write can't mint a fresh key for a deleted plan or a forgotten person.
class PlanEncryptionKey < ApplicationRecord
  REASONS = %w[plan_deleted person_forgotten forgotten].freeze

  acts_as_tenant :tenant

  encrypts :key_material

  validates :plan_id, :cipher, presence: true
  validates :destroyed_reason, inclusion: { in: REASONS }, allow_nil: true

  scope :live, -> { where(destroyed_at: nil) }
  scope :tombstones, -> { where.not(destroyed_at: nil) }
  scope :person_keys, -> { where.not(person_id: nil) }

  # Live person keys whose person the Org Graph has forgotten. After 2.5 this
  # is empty unless something brought the keys back, such as a partial restore.
  scope :outliving_forgotten_people, lambda {
    live.person_keys.where(person_id: Person.unscoped.where.not(forgotten_at: nil).select(:id))
  }

  # @return [String] the raw key bytes
  def raw_key = Base64.strict_decode64(key_material)
end
