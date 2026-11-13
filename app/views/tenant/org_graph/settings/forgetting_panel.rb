# frozen_string_literal: true

# "Forgetting": how many years after someone leaves the Org Graph erases their
# name and identifiers, and whether that happens on a schedule. Who would go
# today loads in a frame after the page, as counting them asks the HRIS who
# is still there.
class Views::Tenant::OrgGraph::Settings::ForgettingPanel < Views::Base
  include Views::Tenant::OrgGraph::Settings::FormHelpers

  YEARS = [ 1, 2, 3, 5, 7, 10, 15, 20 ].freeze

  # @param config [OrgGraphConfig]
  # @param key_set [Boolean] whether this server holds the key forgetting needs
  def initialize(config:, key_set:)
    @config = config
    @key_set = key_set
  end

  def view_template
    render Components::Kit::Card.new(title: "Forgetting", heading_level: :h2, id: "org-graph-forgetting") do |card|
      card.body do
        p(class: "text-sm text-muted") do
          "Some time after a person leaves, the Org Graph erases their name and identifiers. " \
            "Their history stays, shown as a former member."
        end
        retention_form
        schedule
      end
    end
  end

  private

  def retention_form
    settings_form(tenant_org_graph_settings_retention_path, method: :patch, class: "mt-4 flex flex-wrap items-end gap-2") do
      div(class: "flex flex-col gap-1") do
        label(for: "org-graph-retention", class: "text-sm font-medium text-default") { "Forget leavers after" }
        select(id: "org-graph-retention", name: "retention", class: Components::Kit::Field::SELECT) do
          (YEARS | [ years ].compact).sort.each do |choice|
            option(value: choice, selected: choice == years) { "#{choice} #{choice == 1 ? 'year' : 'years'}" }
          end
          option(value: "never", selected: years.nil?) { "Never" }
        end
      end
      render Components::Kit::Button.new(variant: :outline, tone: :neutral, type: :submit, id: "org-graph-retention-save") { "Save" }
    end
  end

  def schedule
    div(class: "mt-4 space-y-3 text-sm") do
      if !@key_set
        render Components::Kit::Alert.new(tone: :warning, title: "Forgetting isn't set up") do
          "This server has no key to forget with, so nobody can be forgotten yet. " \
            "Ask whoever runs Espalia to add it."
        end
      elsif years.nil?
        p(class: "text-default") { "Nobody is forgotten while this is set to never." }
      elsif @config.scheduled_forgetting
        scheduled
      else
        render Views::Tenant::OrgGraph::Settings::ForgettingDueFrame.new(src: tenant_org_graph_settings_forgetting_due_path)
      end
    end
  end

  def scheduled
    p(class: "text-default") do
      plain "Scheduled forgetting is on"
      plain " since #{@config.scheduled_forgetting_enabled_at.to_date.to_fs(:long)}" if @config.scheduled_forgetting_enabled_at
      plain ". Each leaver is forgotten once their date comes."
    end
    settings_form(tenant_org_graph_settings_forgetting_schedule_path, method: :delete) do
      render Components::Kit::Button.new(variant: :outline, tone: :danger, type: :submit, id: "org-graph-forgetting-off") do
        "Turn off scheduled forgetting"
      end
    end
  end

  def years = @config.retention_years
end
