# frozen_string_literal: true

# The one currency a tenant's reports total in (Team Planning 5.3). A pay
# band keeps its own currency; a report converts to this one when it runs.
class ReferenceCurrency < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :updated_by, class_name: "User", optional: true

  normalizes :currency, with: Currency::NORMALIZE

  validates :currency, inclusion: { in: Currency::CODES, message: Currency::INVALID }

  # @return [ReferenceCurrency, nil] the tenant's, until one is set
  def self.current = first
end
