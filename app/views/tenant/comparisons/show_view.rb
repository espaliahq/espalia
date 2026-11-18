# frozen_string_literal: true

# Tenant admin → Comparisons: the switch, the smallest group and the snapshot
# interval, with how snapshots work and when the last and next are.
class Views::Tenant::Comparisons::ShowView < Views::Base
  include Phlex::Rails::Helpers::Routes
  include Phlex::Rails::Helpers::FormWith

  INTERVALS = ComparisonConfig::SNAPSHOT_INTERVALS.to_h { |months| [ months, "#{months} #{'month'.pluralize(months)}" ] }.freeze

  # @param settings [Hash] `Operations::Tenants::Comparisons.payload`
  # @param submitted [Hash] the form as sent, shown again when it couldn't be saved
  # @param user [User]
  # @param current_tenant [Tenant]
  # @param tenants [Array<Tenant>]
  def initialize(settings:, user:, current_tenant:, submitted: {}, tenants: [])
    @settings = settings
    @submitted = submitted
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::TenantAdminLayout.new(
      active_section: :comparisons, user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      render Components::Kit::SectionHeading.new("Comparisons", subtitle: "What people can compare their assessment with.")

      form_with(url: tenant_comparisons_path, method: :patch, scope: :comparisons, class: "space-y-6") do |form|
        render Components::Kit::Card.new(title: "Compare with your level", heading_level: :h2) do |card|
          card.body do
            p(class: "text-sm text-muted mb-4") do
              "Adds a tab to the capability map that compares a person's capabilities with everyone on the " \
                "same role, at their level or one level either side."
            end
            div(class: "divide-y divide-(--gos-border-subtle)") do
              enabled_field(form)
              group_size_field(form)
              interval_field(form)
            end
            how_snapshots_work
          end
        end
        div(class: "flex justify-end") do
          form.submit "Save", class: Components::Kit::Button.classes(tone: :brand, touch: true)
        end
      end
    end
  end

  private

  def field(key) = @submitted.fetch(key, @settings[key])

  def enabled_field(form)
    div(class: "flex items-center gap-3 pb-4") do
      form.hidden_field :enabled, value: "0", id: nil
      form.check_box :enabled, { checked: ActiveModel::Type::Boolean.new.cast(field(:enabled)), class: Components::Kit::Field::CHECKBOX,
                                 id: "comparisons_enabled" }, "1", nil
      label(for: "comparisons_enabled", class: "text-sm font-medium text-default") { "Let people compare with their level" }
    end
  end

  def group_size_field(form)
    div(class: "flex flex-col gap-2 py-4") do
      label(for: "comparisons_min_group_size", class: "text-sm font-medium text-default") { "Smallest group to compare with" }
      form.number_field :min_group_size, value: field(:min_group_size), min: ComparisonConfig::LOWEST_MIN_GROUP_SIZE,
                                         max: ComparisonConfig::HIGHEST_MIN_GROUP_SIZE, id: "comparisons_min_group_size",
                                         class: "#{Components::Kit::Field::INPUT} max-w-24",
                                         aria: { describedby: "comparisons_min_group_size_help" }
      p(id: "comparisons_min_group_size_help", class: "text-sm text-muted") do
        "Counts everyone at that level with a settled assessment. A smaller level shows \"fewer than " \
          "#{@settings[:min_group_size]}\" and no numbers. The capability attainment report hides smaller groups only from " \
          "someone who can't open every assessment in them; everyone who sees that report today can, so it shows them all. " \
          "At least #{ComparisonConfig::LOWEST_MIN_GROUP_SIZE}; default #{ComparisonConfig::DEFAULT_MIN_GROUP_SIZE}."
      end
    end
  end

  def interval_field(form)
    div(class: "flex flex-col gap-2 pt-4") do
      label(for: "comparisons_snapshot_every_months", class: "text-sm font-medium text-default") { "Take a new snapshot every" }
      form.select :snapshot_every_months, INTERVALS.map { |months, words| [ words, months ] },
                  { selected: field(:snapshot_every_months) },
                  id: "comparisons_snapshot_every_months", class: "#{Components::Kit::Field::SELECT} max-w-48"
    end
  end

  def how_snapshots_work
    render Components::Kit::Card.new(variant: :inset, class: "mt-6") do |card|
      card.body do
        h3(class: "text-sm font-semibold text-default mb-2") { "How snapshots work" }
        ul(class: "list-disc space-y-1 pl-5 text-sm text-muted") do
          li { "On the 1st of the month (every month, or every third or sixth), Espalia records each group's median scores. Comparisons show that snapshot until the next one." }
          li { "A group counts each person's latest settled assessment: the agreed ratings from the last alignment their manager completed." }
          li { "Alignments completed in between, and people who join or leave, show up at the next snapshot, so a change in a group's median can't be traced to one person." }
          li { "There's no \"refresh now\": a refresh straight after one alignment would point at that person." }
          li { "The first snapshot is taken when comparisons are turned on. A change to how often counts from the last snapshot, so a shorter interval can make one due straight away." }
        end
        p(class: "mt-3 text-sm text-default") do
          strong { "Last snapshot: " }
          span(data: { last_snapshot: true }) { date(@settings[:last_snapshot_on]) || "none yet" }
          plain " · "
          strong { "Next: " }
          span(data: { next_snapshot: true }) { date(@settings[:next_snapshot_on]) || "none while comparisons are off" }
        end
      end
    end
  end

  def date(iso) = iso && Date.iso8601(iso).strftime(LevelComparisonSnapshot::DATE_FORMAT)
end
