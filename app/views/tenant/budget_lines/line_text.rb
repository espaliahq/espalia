# frozen_string_literal: true

# How a budget line reads on the screen: what it was approved for, its amount
# in its own currency and period, and its head count.
module Views::Tenant::BudgetLines::LineText
  include Views::Tenant::PayBands::BandText

  ORIGINS = { "existing" => "Existing seat", "replacement" => "Replacement", "new" => "New position" }.freeze

  private

  # @param line [Hash] as Operations::Tenants::BudgetLines lists it
  # @return [String] such as "Software Engineer, E2 Engineer II", or "Any role"
  def line_name(line) = [ line[:role], line[:level_name] ].compact.join(", ").presence || "Any role"

  # @param line [Hash]
  # @return [String] such as "AUD 120,000 a year · Head count 2", or "No amount · Head count 2"
  def figures_text(line)
    money = line[:amount] ? "#{line[:currency]} #{amount(line[:amount])} #{PER.fetch(line[:period])}" : "No amount"
    [ money, line[:head_count] && "Head count #{amount(line[:head_count])}" ].compact.join(" · ")
  end

  # @param line [Hash]
  # @return [String] such as "New position, approved 1 Oct 2026 · 1 Jan 2027 to 31 Dec 2027 · Atlantis"
  def terms_text(line)
    origin = ORIGINS.fetch(line[:origin])
    origin += ", approved #{day_text(line[:approved_on])}" if line[:approved_on]
    [ origin, "#{day_text(line[:starts_on])} to #{day_text(line[:ends_on])}", line[:location],
      line[:cost_centre] && "Cost centre #{line[:cost_centre]}" ].compact.join(" · ")
  end
end
