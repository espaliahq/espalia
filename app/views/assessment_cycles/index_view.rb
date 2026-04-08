# frozen_string_literal: true

# Lists assessment cycles for the current tenant, grouped by status.
#
# Open cycles are shown first (prominent), closed cycles afterwards (dimmed).
# Each cycle card links to its detail page and surfaces participant counts.
#
class Views::AssessmentCycles::IndexView < Views::Base
  CYCLE_TYPE_LABELS = {
    "regular" => "Regular",
    "performance_review" => "Performance Review",
    "promotion_review" => "Promotion Review"
  }.freeze

  # @param open_cycles [Array<AssessmentCycle>]
  # @param closed_cycles [Array<AssessmentCycle>]
  # @param participant_counts [Hash{[String, String] => Integer}] keyed by [cycle_id, status]
  # @param can_define_new [Boolean] whether at least one framework lacks an open cycle
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(open_cycles:, closed_cycles:, participant_counts:,
                 can_define_new:, user: nil, current_tenant: nil, tenants: [])
    @open_cycles = open_cycles
    @closed_cycles = closed_cycles
    @participant_counts = participant_counts
    @can_define_new = can_define_new
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-6xl mx-auto px-4 py-8") do
        page_header
        open_section
        closed_section
      end
    end
  end

  private

  def page_header
    render Components::Kit::SectionHeading.new(
      "Assessment Cycles",
      subtitle: "Define and manage review cycles for your frameworks"
    ) do |heading|
      heading.action do
        if @can_define_new
          a(
            href: new_assessment_cycle_path,
            class: "inline-flex items-center rounded-md bg-primary px-3 py-2 " \
                   "text-sm font-semibold text-white shadow-xs hover:bg-primary/90 " \
                   "focus-visible:outline focus-visible:outline-2 " \
                   "focus-visible:outline-offset-2 focus-visible:outline-primary transition-colors"
          ) { "Define new cycle" }
        end
      end
    end
  end

  def open_section
    div(class: "mt-6") do
      h3(class: "text-lg font-semibold text-gray-900 dark:text-white mb-4") do
        plain "Open (#{@open_cycles.size})"
      end

      if @open_cycles.any?
        div(class: "grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6") do
          @open_cycles.each { |cycle| cycle_card(cycle, dimmed: false) }
        end
      else
        empty_state("No open cycles.")
      end
    end
  end

  def closed_section
    return if @closed_cycles.empty?

    div(class: "mt-10") do
      h3(class: "text-lg font-semibold text-gray-900 dark:text-white mb-4") do
        plain "Closed (#{@closed_cycles.size})"
      end
      div(class: "grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6") do
        @closed_cycles.each { |cycle| cycle_card(cycle, dimmed: true) }
      end
    end
  end

  def cycle_card(cycle, dimmed:)
    a(
      href: assessment_cycle_path(cycle),
      class: "block group #{'opacity-70 hover:opacity-100' if dimmed} transition-opacity"
    ) do
      render Components::Kit::Card.new do |card|
        card.body do
          div(class: "flex items-start justify-between gap-3") do
            div do
              h3(
                class: "text-lg font-semibold text-gray-900 dark:text-white " \
                       "group-hover:text-primary transition-colors"
              ) { cycle.name }
              p(class: "mt-1 text-sm text-gray-500 dark:text-gray-400") do
                plain framework_label(cycle)
              end
            end
            render Components::Kit::Badge.new(cycle_type_label(cycle), variant: :info)
          end

          div(class: "mt-4 flex flex-wrap gap-2 text-xs") do
            render Components::Kit::Badge.new(
              "v#{cycle.framework_version}", variant: :default
            )
            render Components::Kit::Badge.new(
              "#{active_participant_count(cycle)} participants", variant: :default
            )
            render Components::Kit::Badge.new(
              cycle.open? ? "Open" : "Closed",
              variant: cycle.open? ? :success : :default
            )
          end

          div(class: "mt-3 text-xs text-gray-500 dark:text-gray-400") do
            plain "Opened #{cycle.opened_at.to_fs(:long)}"
          end
        end
      end
    end
  end

  def framework_label(cycle)
    cycle.framework&.name || "Framework unavailable"
  end

  def cycle_type_label(cycle)
    CYCLE_TYPE_LABELS.fetch(cycle.cycle_type, cycle.cycle_type)
  end

  def active_participant_count(cycle)
    @participant_counts
      .select { |(cid, status), _| cid == cycle.cycle_id && status != "withdrawn" }
      .values
      .sum
  end

  def empty_state(message)
    div(class: "text-center py-12") do
      p(class: "text-gray-500 dark:text-gray-400") { message }
    end
  end
end
