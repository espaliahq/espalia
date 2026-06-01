# frozen_string_literal: true

# Framework settings configuration page.
#
# Displays scoring threshold settings with the ability to customise
# values or revert to system defaults. Designed as a sectioned layout
# so future setting groups can be added alongside scoring.
#
class Views::Frameworks::SettingsView < Views::Base
  SETTINGS = [
    {
      key: :mastery_threshold,
      label: "Mastery Threshold",
      description: "The performance ratio a person must reach to be considered 'mastering' their " \
                   "current level. Higher values require stronger over-performance. Blocked " \
                   "capabilities prevent mastery regardless of score.",
      type: :decimal,
      step: "0.01",
      min: "0.01"
    },
    {
      key: :meeting_expectation_threshold,
      label: "Meeting Expectations Threshold",
      description: "The minimum performance ratio to be considered 'meeting expectations'. " \
                   "Also used as the score gate for promotion readiness at the next level.",
      type: :decimal,
      step: "0.01",
      min: "0.01"
    },
    {
      key: :underperforming_threshold,
      label: "Underperforming Threshold",
      description: "The performance ratio below which a person is classified as " \
                   "'underperforming' rather than 'progressing'. Between this value and " \
                   "the meeting threshold the person is considered to be progressing toward " \
                   "their current level.",
      type: :decimal,
      step: "0.01",
      min: "0.01"
    },
    {
      key: :overperformance_cap,
      label: "Over-performance Cap",
      description: "How many levels above a person's assigned level contribute to their score. " \
                   "Ratings beyond this cap are visible but don't inflate the score. " \
                   "Set to 0 to ignore all above-level ratings.",
      type: :integer,
      step: "1",
      min: "0"
    },
    {
      key: :deficit_threshold,
      label: "Deficit Threshold",
      description: "The weighted deficit above which a capability is flagged as 'blocked'. " \
                   "Blocked capabilities prevent meeting-expectations and mastery verdicts. " \
                   "Set to 0 to make every capability mandatory (any gap blocks).",
      type: :decimal,
      step: "0.01",
      min: "0"
    }
  ].freeze

  # @param framework [FrameworkState::Framework]
  # @param scoring_defaults [Hash] system default values keyed by setting name
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(framework:, scoring_defaults:, user: nil, current_tenant: nil, tenants: [])
    @framework = framework
    @defaults = scoring_defaults
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-3xl mx-auto px-4 py-8 space-y-12") do
        page_header
        settings_form
        collaborators_section
      end
    end
  end

  private

  def page_header
    div(class: "mb-8") do
      a(
        href: framework_path(@framework.framework_id),
        class: "text-sm text-gray-600 dark:text-gray-300 hover:text-gray-700 " \
               "dark:hover:text-gray-200 transition-colors"
      ) do
        plain "\u2190 Back to #{@framework.name}"
      end

      h1(class: "mt-2 text-2xl font-bold text-gray-900 dark:text-white") { "Settings" }
      p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
        plain "Configure how assessments are scored and evaluated for this framework."
      end
    end
  end

  def settings_form
    form(
      action: framework_settings_path(@framework.framework_id),
      method: "post",
      class: "space-y-10"
    ) do
      input(type: "hidden", name: "_method", value: "patch")
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)

      scoring_section
      submit_section
    end
  end

  def collaborators_section
    div do
      render Components::Kit::SectionHeading.new(
        "Collaborators",
        subtitle: "People who can view, suggest, or directly edit this framework"
      )

      turbo_frame_tag(
        "framework-collaborators",
        src: framework_collaborators_path(@framework.framework_id),
        loading: "lazy",
        class: "block mt-6"
      ) do
        p(class: "text-sm text-gray-600 dark:text-gray-300") { "Loading collaborators…" }
      end
    end
  end

  def scoring_section
    div do
      render Components::Kit::SectionHeading.new(
        "Scoring Thresholds",
        subtitle: "Control how performance ratios and capability deficits are evaluated"
      )

      div(class: "mt-6 space-y-6") do
        SETTINGS.each { |setting| setting_card(setting) }
      end
    end
  end

  def setting_card(setting)
    key = setting[:key]
    current_value = @framework.public_send(key)
    default_value = @defaults[key]
    display_value = current_value.nil? ? default_value : current_value
    is_default = current_value.nil? || current_value.to_f == default_value.to_f

    render Components::Kit::Card.new do |card|
      card.body do
        div(
          data: {
            controller: "setting-field",
            setting_field_default_value: format_value(default_value, setting[:type])
          }
        ) do
          # Label and description
          div(class: "mb-4") do
            div(class: "flex items-center gap-2") do
              h3(class: "text-sm font-semibold text-gray-900 dark:text-white") { setting[:label] }
              if is_default
                span(class: "inline-flex items-center rounded-full bg-gray-100 dark:bg-gray-700 " \
                            "px-2 py-0.5 text-xs font-medium text-gray-600 dark:text-gray-300") do
                  plain "System default"
                end
              end
            end
            p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") { setting[:description] }
          end

          # Input field
          div(class: "flex items-center gap-3") do
            input(
              type: "number",
              name: "settings[#{key}]",
              value: format_value(display_value, setting[:type]),
              step: setting[:step],
              min: setting[:min],
              class: "block w-32 rounded-sm border border-gray-300 dark:border-gray-600 " \
                     "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
                     "shadow-xs focus:border-primary focus:ring-1 focus:ring-primary " \
                     "focus:outline-hidden transition-colors",
              data: {
                setting_field_target: "input",
                action: "input->setting-field#checkDefault"
              }
            )

            # Reset to default link
            button(
              type: "button",
              class: "text-sm text-primary hover:text-primary/80 transition-colors #{'hidden' if is_default}",
              data: {
                setting_field_target: "reset",
                action: "setting-field#reset"
              }
            ) do
              plain "\u21A9 Reset to default (#{format_value(default_value, setting[:type])})"
            end
          end
        end
      end
    end
  end

  def submit_section
    div(class: "flex items-center gap-4") do
      button(
        type: "submit",
        class: "inline-flex items-center rounded-sm bg-primary px-4 py-2 text-sm " \
               "font-semibold text-white shadow-xs hover:bg-primary/90 " \
               "focus:outline-hidden focus:ring-2 focus:ring-primary focus:ring-offset-2 " \
               "transition-colors"
      ) { "Save settings" }

      a(
        href: framework_path(@framework.framework_id),
        class: "text-sm text-gray-600 dark:text-gray-300 hover:text-gray-700 " \
               "dark:hover:text-gray-200 transition-colors"
      ) { "Cancel" }
    end
  end

  # @param value [Numeric] the value to format
  # @param type [Symbol] :decimal or :integer
  # @return [String]
  def format_value(value, type)
    case type
    when :integer then value.to_i.to_s
    else value.to_f.to_s
    end
  end
end
