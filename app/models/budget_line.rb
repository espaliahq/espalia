# frozen_string_literal: true

# One line of the tenant's approved headcount budget (Team Planning 6.1):
# permission to spend on people over a period. It holds an amount, a head
# count or both, and may name the role, level, location and cost centre it
# was approved for. Every plan's scenarios start from these lines.
#
# An amount keeps its own currency and period, as a pay band's does, and is
# never converted. A line with only a head count has no amount, never zero.
# It names no person and holds no accounting identifier: a cost centre is the
# label the Org Graph carries for a person.
class BudgetLine < ApplicationRecord
  PERIODS = %w[year month].freeze
  ORIGINS = %w[existing replacement new].freeze

  acts_as_tenant :tenant

  belongs_to :tenant
  # The previous releases named an account here; a4b drops it once no
  # deployed release writes it.
  self.ignored_columns += %w[updated_by_id]

  normalizes :currency, with: Currency::NORMALIZE
  normalizes :location, with: ->(location) { PayBand.known_spelling(location.to_s.squish) }, apply_to_nil: true
  normalizes :cost_centre, with: ->(label) { label.to_s.squish }, apply_to_nil: true

  validates :starts_on, :ends_on, presence: true
  validates :origin, inclusion: { in: ORIGINS, message: "must be existing, replacement or new" }
  validates :amount, numericality: { greater_than_or_equal_to: 0, less_than: 10**12 }, allow_nil: true
  validates :head_count, numericality: { greater_than: 0, less_than: 10**6 }, allow_nil: true
  validates :currency, inclusion: { in: Currency::CODES, message: Currency::INVALID }, if: :amount
  validates :period, inclusion: { in: PERIODS, message: "must be year or month" }, if: :amount
  validate :amount_or_head_count
  validate :period_in_order

  before_validation { self.currency = self.period = nil unless amount }
  before_validation { self.approved_on = nil unless origin == "new" }

  # Takes the level and copies its names and role, so the line still reads
  # once the level leaves the framework.
  #
  # @param level [FrameworkState::Level]
  # @param role [FrameworkState::Role, nil]
  def take_level(level, role = FrameworkState::Role.find_by(role_id: level.role_id))
    self.level_id = level.level_id
    self.level_name = "#{level.code} #{level.title}".strip
    take_role(role, level.role_id)
  end

  # @param role [FrameworkState::Role, nil]
  # @param role_id [String]
  def take_role(role, role_id = role&.role_id)
    self.role_id = role_id
    self.role_name = role&.name.presence || "Unnamed role"
  end

  # Clears the role and level, for a line approved for any role.
  def any_role!
    self.role_id = self.level_id = self.role_name = self.level_name = nil
  end

  # @return [String, nil] such as "Software Engineer, E4 Staff Engineer", or the role alone
  def role_label = [ role_name, level_name ].compact.join(", ").presence

  # @param name [Symbol] :amount or :head_count
  # @return [String, nil] the figure with its decimal places, "120000.00", or nil when the line has none
  def figure(name) = self.class.figure_of(public_send(name))

  # @param value [BigDecimal, String, nil]
  # @return [String, nil] such as "120000.00"
  def self.figure_of(value)
    return nil if value.nil?

    whole, fraction = BigDecimal(value.to_s).to_s("F").split(".")
    "#{whole}.#{fraction.to_s.ljust(2, '0')}"
  end

  private

  def amount_or_head_count
    errors.add(:base, "A budget line needs an amount, a head count or both") if amount.nil? && head_count.nil?
  end

  def period_in_order
    errors.add(:base, "A budget line can't end before it starts") if starts_on && ends_on && ends_on < starts_on
  end
end
