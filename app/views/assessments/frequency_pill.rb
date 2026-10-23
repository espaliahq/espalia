# frozen_string_literal: true

# Inline rating pill that reads as part of the expectation sentence.
#
# Replaces the previous 4-button segmented selector with a single colour
# coded pill ("Most of the time ▾") that opens a popover with the four
# frequency options + Clear. The popover items are real <button>s inside
# real <form>s so the rating still POSTs through the existing rating
# controllers — no custom XHR.
#
# When `interactive: false` the pill renders as a plain colour-coded
# span (no chevron, no popover) — used in `aligning` / `aligned` states
# where the rating is frozen but should still read as a sentence.
#
# @example
#   render Views::Assessments::FrequencyPill.new(
#     capability_stable_id: stable_id,
#     level_ordinal: 3,
#     current_frequency: "consistent",
#     assessment_id: assignment.id,
#     context: :self,
#     category_id: category_id
#   )
#
class Views::Assessments::FrequencyPill < Views::Base
  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  # @param current_frequency [String, nil]
  # @param assessment_id [String]
  # @param context [Symbol] :self, :manager, or :alignment
  # @param category_id [String, nil] active category for tab preservation on rating
  # @param interactive [Boolean] false for frozen / locked states
  # @param carried [Boolean] true when the shown value is a carried-forward
  #   (seeded) rating the viewer hasn't confirmed — renders as a dashed
  #   outline in the frequency's hue instead of the solid soft fill, and
  #   re-selecting the shown value confirms rather than clears
  # @param lens_params [Hash] the lens the page is read through (`as_role` /
  #   `as_level`), forwarded so the rating is made — and the response
  #   re-rendered — through it
  # @param static_title [String, nil] overrides the frozen pill's tooltip,
  #   for a pill that is read-only for a reason other than a freeze
  def initialize(capability_stable_id:, level_ordinal:, current_frequency:,
                 assessment_id:, context: :self, category_id: nil,
                 interactive: true, carried: false, lens_params: {}, static_title: nil)
    @capability_stable_id = capability_stable_id
    @level_ordinal = level_ordinal
    @current_frequency = current_frequency
    @assessment_id = assessment_id
    @context = context
    @category_id = category_id
    @interactive = interactive
    @carried = carried
    @lens_params = lens_params
    @static_title = static_title
  end

  def view_template
    if @interactive
      interactive_pill
    else
      static_pill
    end
  end

  private

  # Pill wrapped in a dropdown — click reveals the popover with four
  # options + Clear. ARIA mirrors the comment kebab pattern.
  def interactive_pill
    div(
      class: "relative inline-block",
      data: {
        controller: "dropdown submit-fallback",
        submit_fallback_text_value: "Couldn't save this rating — check your connection and try again.",
        action: "keydown.esc@window->dropdown#close " \
                "turbo:before-fetch-response->submit-fallback#beforeFetchResponse " \
                "turbo:submit-start->submit-fallback#submitStart " \
                "turbo:submit-end->submit-fallback#submitEnd"
      }
    ) do
      pill_trigger
      popover
      transport_error_region
    end
  end

  # Pre-existing empty live region for transport-level submit failures
  # (submit-fallback controller, audit issue #316). Positioned below the
  # pill; empty and hidden until a failure injects the message.
  def transport_error_region
    render Components::Shared::SubmitFallbackMessage.new(
      classes: "absolute left-0 top-full mt-1 z-20 w-max max-w-64"
    )
  end

  # Frozen variant — same colour treatment, no chevron, no interaction.
  def static_pill
    span(
      class: "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium #{pill_bg_classes}",
      title: @static_title || (@carried ? "#{phrase} — carried forward from #{carried_origin}" : phrase)
    ) { phrase }
  end

  # Whose history the carried value came from — second person only when the
  # viewer IS the rated party (:self). In :manager context the value is the
  # manager's prior rating of their REPORT's cycle; "your previous cycle"
  # would misattribute it (the YOU vs CURRENT badge precedent).
  def carried_origin
    @context == :self ? "your previous cycle" : "the previous cycle"
  end

  def pill_trigger
    button(
      type: "button",
      class: "inline-flex min-h-6 items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium " \
             "#{pill_bg_classes} cursor-pointer " \
             "hover:brightness-95 dark:hover:brightness-110 transition " \
             "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary",
      title: @carried ? "Carried forward from #{carried_origin} — confirm or change" : nil,
      data: { dropdown_target: "trigger", action: "dropdown#toggle", carried: @carried ? "true" : nil },
      aria: { label: trigger_aria_label, haspopup: "menu", expanded: "false" }
    ) do
      span { phrase }
      # The dashed outline alone was easy to miss (#480): say it in the label.
      span(class: "font-normal", aria_hidden: "true") { "· confirm" } if @carried
      span(class: "text-[10px] leading-none", aria_hidden: "true") { "▾" }
    end
  end

  def trigger_aria_label
    if @carried
      "Rated #{phrase.downcase}, carried forward from #{carried_origin} — confirm or change"
    else
      "Rated #{phrase.downcase} — change"
    end
  end

  def popover
    div(
      class: "hidden absolute left-0 mt-1 z-30 w-44 rounded-md border border-gray-200 " \
             "dark:border-gray-700 bg-white dark:bg-gray-900 shadow-lg py-1 text-xs",
      role: "menu",
      data: { dropdown_target: "menu" }
    ) do
      if @carried
        carried_note
        keep_button
        divider
      end
      Views::Assessments::FrequencyPalette::ORDERED_KEYS.each do |key|
        option_button(key)
      end
      divider if @current_frequency.present?
      clear_button if @current_frequency.present?
    end
  end

  # Header line inside the popover when the value is carried forward — where
  # it came from, above the Keep button that confirms it.
  def carried_note
    origin = @context == :self ? "your last cycle" : "the last cycle"
    div(class: "px-3 py-1.5 text-[11px] text-gray-600 dark:text-gray-300") do
      plain "Carried from #{origin}. Keep it for this cycle, or pick another value."
    end
  end

  def option_button(key)
    config = Views::Assessments::FrequencyPalette.config_for(key)
    selected = @current_frequency == key

    form(
      action: form_action,
      method: "post",
      data: { turbo_stream: "true" },
      class: "contents"
    ) do
      hidden_inputs(frequency: key)

      button(
        type: "submit",
        role: "menuitem",
        class: "flex w-full items-center gap-2 px-3 py-1.5 text-left text-gray-700 " \
               "dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700 " \
               "#{selected ? 'font-semibold' : ''}",
        data: { action: "click->dropdown#close" }
      ) do
        span(class: "w-2 h-2 rounded-full #{config[:dot]} shrink-0")
        span(class: "flex-1") { config[:phrase] }
        span(class: "text-[10px] text-gray-400") { "✓" } if selected
      end
    end
  end

  # Confirming used to mean "pick the value already selected", which nobody
  # guessed. The explicit marker makes a second click, or a stale tab, a
  # no-op instead of the untoggle that would clear a confirmed rating.
  def keep_button
    form(action: form_action, method: "post", data: { turbo_stream: "true" }, class: "contents") do
      hidden_inputs(frequency: @current_frequency, confirm: true)
      button(
        type: "submit",
        role: "menuitem",
        class: "flex w-full items-center gap-2 px-3 py-1.5 text-left font-semibold text-gray-900 " \
               "dark:text-white hover:bg-gray-100 dark:hover:bg-gray-700",
        data: { action: "click->dropdown#close" }
      ) { "Keep “#{phrase}”" }
    end
  end

  def clear_button
    # Explicit `rating[clear]` marker: the implicit same-frequency
    # untoggle can't be trusted here any more — on a carried rating the
    # same-frequency POST means CONFIRM, so Clear must say what it means.
    form(
      action: form_action,
      method: "post",
      data: { turbo_stream: "true" },
      class: "contents"
    ) do
      hidden_inputs(frequency: @current_frequency, clear: true)

      button(
        type: "submit",
        role: "menuitem",
        class: "block w-full text-left px-3 py-1.5 text-gray-600 dark:text-gray-300 " \
               "hover:bg-gray-100 dark:hover:bg-gray-700",
        data: { action: "click->dropdown#close" }
      ) { "Clear rating" }
    end
  end

  def divider
    div(class: "my-1 border-t border-gray-100 dark:border-gray-800")
  end

  def hidden_inputs(frequency:, clear: false, confirm: false)
    input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
    input(type: "hidden", name: "rating[capability_stable_id]", value: @capability_stable_id)
    input(type: "hidden", name: "rating[level_ordinal]", value: @level_ordinal)
    input(type: "hidden", name: "rating[frequency]", value: frequency)
    input(type: "hidden", name: "rating[clear]", value: "1") if clear
    input(type: "hidden", name: "rating[confirm]", value: "1") if confirm
    input(type: "hidden", name: "rating[category_id]", value: @category_id) if @category_id
    @lens_params.each { |name, value| input(type: "hidden", name: name.to_s, value: value) }
  end

  def pill_bg_classes
    config = Views::Assessments::FrequencyPalette.config_for(@current_frequency)
    return "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300" unless config

    @carried ? config[:pill_carried] : config[:pill_bg]
  end

  def phrase
    Views::Assessments::FrequencyPalette.phrase_for(@current_frequency)
  end

  def form_action
    case @context
    when :manager   then assessment_manager_ratings_path(@assessment_id)
    when :alignment then assessment_alignment_ratings_path(@assessment_id)
    else                 assessment_ratings_path(@assessment_id)
    end
  end
end
