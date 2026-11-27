# frozen_string_literal: true

# One change to a tenant setting that past answers depend on, recorded by
# {Tenant} in the save that makes it, so a reader of the past can use the
# value in force then. Rows are never changed.
#
# The migration that created the table wrote each tenant's values that day,
# dated from the tenant's creation: what we know was in force.
class TenantSettingChange < ApplicationRecord
  SETTINGS = %w[time_zone min_group_size].freeze

  acts_as_tenant :tenant

  validates :setting, inclusion: { in: SETTINGS }
  validates :value, :changed_at, presence: true
  validates :value, format: { with: /\A\d+\z/, message: "must be a whole number" }, if: -> { setting == "min_group_size" }

  # @return [Boolean] true once saved, so a row can't be updated or destroyed
  def readonly?
    persisted? || super
  end
end
