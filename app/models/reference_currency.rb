# frozen_string_literal: true

# The one currency a tenant's reports total in (Team Planning 5.3). A pay
# band keeps its own currency; a report converts to this one when it runs.
class ReferenceCurrency < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :tenant
  # The previous releases named an account here; a4b drops it once no
  # deployed release writes it.
  self.ignored_columns += %w[updated_by_id]

  normalizes :currency, with: Currency::NORMALIZE

  validates :currency, inclusion: { in: Currency::CODES, message: Currency::INVALID }

  # @return [ReferenceCurrency, nil] the tenant's, until one is set
  def self.current = first
end
