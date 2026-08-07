# frozen_string_literal: true

# Lists calibration sessions visible to the viewer — sessions they
# facilitate, or every session for admins. Grouped by lifecycle status.
class Views::CalibrationSessions::IndexView < Views::Base
  STATUS_VARIANTS = { "draft" => :warning, "started" => :success, "closed" => :default }.freeze
  STATUS_LABELS = { "draft" => "Draft", "started" => "Live", "closed" => "Closed" }.freeze

  # @param sessions [Array<CalibrationSession>]
  # @param cycles [Hash{String => AssessmentCycle}] keyed by cycle_id
  # @param member_counts [Hash{[String, String] => Integer}] keyed by [session_id, member_type]
  # @param can_define [Boolean]
  def initialize(sessions:, cycles:, member_counts:, can_define:,
                 user: nil, current_tenant: nil, tenants: [])
    @sessions = sessions
    @cycles = cycles
    @member_counts = member_counts
    @can_define = can_define
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-[max(72rem,80vw)] mx-auto px-4 py-8") do
        page_header
        if @sessions.any?
          div(class: "mt-6 grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6") do
            @sessions.each { |session| session_card(session) }
          end
        else
          empty_state
        end
      end
    end
  end

  private

  def page_header
    render Components::Kit::SectionHeading.new(
      "Calibration",
      subtitle: "Run sessions with your managers to calibrate how they rate their reports"
    ) do |heading|
      heading.action do
        if @can_define
          a(
            href: new_calibration_session_path,
            class: "inline-flex items-center rounded-md bg-primary px-3 py-2 " \
                   "text-sm font-semibold text-white shadow-xs hover:bg-primary/90 " \
                   "focus-visible:outline focus-visible:outline-2 " \
                   "focus-visible:outline-offset-2 focus-visible:outline-primary transition-colors"
          ) { "Define calibration session" }
        end
      end
    end
  end

  def session_card(session)
    a(href: calibration_session_path(session), class: "block group transition-opacity #{'opacity-70 hover:opacity-100' if session.closed?}") do
      render Components::Kit::Card.new do |card|
        card.body do
          div(class: "flex items-start justify-between gap-3") do
            div do
              h3(class: "text-lg font-semibold text-gray-900 dark:text-white group-hover:text-primary transition-colors") do
                session.name
              end
              p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
                plain @cycles[session.cycle_id]&.name || "Cycle unavailable"
              end
            end
            render Components::Kit::Badge.new(
              STATUS_LABELS.fetch(session.status, session.status),
              variant: STATUS_VARIANTS.fetch(session.status, :default)
            )
          end

          div(class: "mt-4 flex flex-wrap gap-2 text-xs") do
            render Components::Kit::Badge.new(
              "#{count_for(session, 'participant')} raters", variant: :default
            )
            render Components::Kit::Badge.new(
              "#{count_for(session, 'calibrant')} calibrated", variant: :default
            )
          end
        end
      end
    end
  end

  def count_for(session, member_type)
    @member_counts.fetch([ session.id, member_type ], 0)
  end

  def empty_state
    div(class: "text-center py-12") do
      p(class: "text-gray-600 dark:text-gray-300") do
        plain "No calibration sessions yet."
      end
      if @can_define
        p(class: "mt-2 text-sm text-gray-600 dark:text-gray-300") do
          plain "Define one to compare how your managers rate their reports."
        end
      end
    end
  end
end
