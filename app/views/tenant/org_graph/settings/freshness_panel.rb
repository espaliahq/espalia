# frozen_string_literal: true

# "Keeping facts fresh": how many days a fact Espalia holds may go without a
# change or a confirmation, and how many have gone that long.
class Views::Tenant::OrgGraph::Settings::FreshnessPanel < Views::Base
  include Views::Tenant::OrgGraph::Settings::FormHelpers
  include Views::Tenant::OrgGraph::Settings::FactLabels

  CHOICES = [ 30, 60, 90, 180, 365 ].freeze

  # @param freshness [Hash] staleness_days, stale and stale_by_fact, as Operations::OrgGraph::Sources reads them
  def initialize(freshness:)
    @freshness = freshness
  end

  def view_template
    render Components::Kit::Card.new(title: "Keeping facts fresh", heading_level: :h2, id: "org-graph-freshness") do |card|
      card.body do
        p(class: "text-sm text-muted") do
          "A fact Espalia holds, such as a title or a manager, counts as stale once nobody has changed or " \
            "confirmed it for this long. Facts the HRIS supplies are kept fresh by each sync."
        end
        threshold_form
        stale_summary
      end
    end
  end

  private

  def threshold_form
    settings_form(tenant_org_graph_settings_freshness_path, method: :patch, class: "mt-4 flex flex-wrap items-end gap-2") do
      div(class: "flex flex-col gap-1") do
        label(for: "org-graph-staleness-days", class: "text-sm font-medium text-default") { "Stale after" }
        select(id: "org-graph-staleness-days", name: "staleness_days", class: Components::Kit::Field::SELECT) do
          (CHOICES | [ days ]).sort.each do |choice|
            option(value: choice, selected: choice == days) { "#{choice} days" }
          end
        end
      end
      render Components::Kit::Button.new(variant: :outline, tone: :neutral, type: :submit, id: "org-graph-freshness-save") { "Save" }
    end
  end

  def stale_summary
    stale = @freshness[:stale]
    p(class: "mt-4 text-sm text-default") do
      stale.zero? ? "No fact is stale." : "#{stale} #{stale == 1 ? 'fact is' : 'facts are'} stale:"
    end
    return if stale.zero?

    ul(class: "mt-1 text-sm text-muted") do
      @freshness[:stale_by_fact].sort_by { |_, count| -count }.each do |fact, count|
        li { "#{fact_label(fact)}: #{count}" }
      end
    end
  end

  def days = @freshness[:staleness_days]
end
