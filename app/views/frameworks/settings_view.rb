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
      description: "The score at which a person is considered to be mastering their level — well " \
                   "on the way to the next one. With the default cap scores run from 0 to 200: 1.00 " \
                   "is meeting every expectation at the assessed level, 2.00 is demonstrating the " \
                   "next level in full (each extra level the cap allows adds another 100), " \
                   "so #{'%.2f' % PersonDevelopment::Scoring::DEFAULT_MASTERY_THRESHOLD} is halfway. " \
                   "Blocked capabilities prevent mastery regardless of score.",
      type: :decimal,
      step: "0.01",
      min: "0.01"
    },
    {
      key: :meeting_expectation_threshold,
      label: "Meeting Expectations Threshold",
      description: "The minimum score to be considered 'meeting expectations' (1.00 is every " \
                   "capability consistent at the assessed level). The next level must clear the same " \
                   "bar for promotion readiness. Must sit above the underperforming threshold and " \
                   "below the mastery threshold.",
      type: :decimal,
      step: "0.01",
      min: "0.01"
    },
    {
      key: :underperforming_threshold,
      label: "Underperforming Threshold",
      description: "The score below which a person is classified as 'underperforming' rather " \
                   "than 'progressing'. Between this value and the meeting threshold the person " \
                   "is considered to be progressing toward their current level.",
      type: :decimal,
      step: "0.01",
      min: "0.01"
    },
    {
      key: :overperformance_cap,
      label: "Over-performance Cap",
      description: "How many levels above a person's assessed level contribute to their score — " \
                   "each level adds up to 100 points. Ratings beyond this cap are visible but " \
                   "don't inflate the score. Set to 0 to ignore all above-level ratings.",
      type: :integer,
      step: "1",
      min: "0"
    },
    {
      key: :deficit_threshold,
      label: "Deficit Threshold",
      description: "The weighted deficit in a capability's ratings above which it is flagged as " \
                   "'blocked'; an unrated capability is never blocked. " \
                   "At #{'%.2f' % PersonDevelopment::Scoring::DEFAULT_DEFICIT_THRESHOLD} a 'not yet' " \
                   "at the assessed level blocks, while 'some' and 'most of " \
                   "the time' can be made up by strength elsewhere. Blocked capabilities prevent " \
                   "meeting-expectations and mastery verdicts. Set to 0 to make every capability " \
                   "required: any rated gap blocks, and nothing above the level counts until it is " \
                   "consistent.",
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
    render Components::Shell::PageLayout.new(
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
        class: "text-sm text-muted hover:text-default transition-colors"
      ) do
        plain "\u2190 Back to #{@framework.name}"
      end

      h1(class: "mt-2 text-2xl font-bold text-default") { "Settings" }
      p(class: "mt-1 text-sm text-muted") do
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
        p(class: "text-sm text-muted") { "Loading collaborators…" }
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
              h3(class: "text-sm font-semibold text-default") { setting[:label] }
              if is_default
                render Components::Kit::Badge.new("System default")
              end
            end
            p(class: "mt-1 text-sm text-muted") { setting[:description] }
          end

          # Input field
          div(class: "flex items-center gap-3") do
            div(class: "w-32") do
              input(
                type: "number",
                name: "settings[#{key}]",
                value: format_value(display_value, setting[:type]),
                step: setting[:step],
                min: setting[:min],
                class: Components::Kit::Field::INPUT,
                data: {
                  setting_field_target: "input",
                  action: "input->setting-field#checkDefault"
                }
              )
            end

            # The controller toggles `hidden` here, because the button's own display class would win over it
            span(class: ("hidden" if is_default), data: { setting_field_target: "reset" }) do
              render Components::Kit::Button.new(
                variant: :link, tone: :brand, size: :sm, data: { action: "setting-field#reset" }
              ) do
                plain "\u21A9 Reset to default (#{format_value(default_value, setting[:type])})"
              end
            end
          end
        end
      end
    end
  end

  def submit_section
    div(class: "flex items-center gap-4") do
      render Components::Kit::Button.new(tone: :brand, type: :submit) { "Save settings" }
      render Components::Kit::Button.new(variant: :ghost, href: framework_path(@framework.framework_id)) { "Cancel" }
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
