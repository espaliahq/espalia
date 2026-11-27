# frozen_string_literal: true

# One change to an account's `users.global_admin`, recorded by {User} in the
# save that makes it. Rows are never changed or deleted. A row names the
# account by id only, so once the account is gone it names nobody.
#
# `baseline` marks who held the flag when recording began. Only the migration
# that created the table writes it.
class GlobalAdminChange < ApplicationRecord
  SOURCES = %w[admin_task seed console baseline].freeze
  RECORDABLE_SOURCES = (SOURCES - %w[baseline]).freeze

  validates :user_id, presence: true
  validates :global_admin, inclusion: { in: [ true, false ] }
  validates :source, inclusion: { in: RECORDABLE_SOURCES }, on: :create

  # @return [Boolean] true once saved, so a row can't be updated or destroyed
  def readonly?
    persisted? || super
  end

  # Rails lets `delete` remove a read-only row, so a saved row refuses it here.
  #
  # @raise [ActiveRecord::ReadOnlyRecord] once saved
  def delete
    raise ActiveRecord::ReadOnlyRecord, "#{self.class} is append-only" if persisted?

    super
  end
end
