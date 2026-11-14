# frozen_string_literal: true

# Wording the Units view's parts share, so a count or a provider reads the
# same in the tree, the panel, a drawer and the sidebar.
module Views::Tenant::OrgGraph::Formatting
  # @param unit [OrgUnit]
  # @return [String] e.g. "HiBob"
  def provider_label(unit) = HrisConfig.provider_label(unit.provider)

  # @param count [Integer]
  # @return [String] e.g. "1 person", "4 people"
  def people(count) = "#{count} #{'person'.pluralize(count)}"

  # @param count [Integer]
  # @param name [String] a taxonomy level's name
  # @return [String] e.g. "3 teams"
  def pluralize_level(count, name) = "#{count} #{name.downcase.pluralize(count)}"
end
