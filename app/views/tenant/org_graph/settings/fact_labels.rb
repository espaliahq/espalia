# frozen_string_literal: true

# What the settings panels call each kind of fact about a person.
module Views::Tenant::OrgGraph::Settings::FactLabels
  LABELS = {
    "employment_status" => "Employment status",
    "title" => "Title",
    "level" => "Level",
    "manager" => "Manager",
    "cost_centre" => "Cost centre",
    "site" => "Site",
    "employment" => "Hours and contract",
    OrgGraph::FactConfirmation::MEMBERSHIP => "Team membership"
  }.freeze

  private

  # @param fact [String]
  # @return [String]
  def fact_label(fact) = LABELS.fetch(fact.to_s) { fact.to_s.humanize }
end
