# frozen_string_literal: true

# The model's suggested placements for one piece of feedback, under its hub
# card: capability · level, the valence it reads as, how confident the model
# is, and the words in the feedback it rests on (a decision model such as Jev
# gives no words, only the confidence). Each row is accepted or
# dismissed in place; "Adjust" opens the evidence modal with every suggestion
# staged as an "Applies to" row; "Suggest again" asks for a fresh set.
#
# Rendered with the same id by the hub and by the accept / dismiss / suggest
# responses, which replace it. The status line beside it is a separate,
# persistent live region the responses update, so screen readers hear what
# happened.
class Views::Evidence::PlacementSuggestions < Views::Base
  include Phlex::Rails::Helpers::FormWith
  include Views::Evidence::Valence

  LINK_BTN = Components::Kit::Button.classes(variant: :link, tone: :brand, touch: true)

  # @param item_id [String]
  # @return [String]
  def self.dom_id_for(item_id) = "evidence-suggestions-#{item_id}"

  # @param item_id [String]
  # @return [String] the status line the responses update
  def self.status_id_for(item_id) = "evidence-suggestions-status-#{item_id}"

  # @param item [EvidenceItem]
  # @param suggestions [Array<EvidencePlacementSuggestion>] pending, most confident first
  # @param cells [Hash{String => Hash}] suggestion id => { name:, level_code:, expectation: }
  # @param can_regenerate [Boolean] whether "Suggest again" is on offer
  #   (the tenant has suggestions on and a model is configured)
  # @param offer_when_empty [Boolean] with no suggestions, whether to offer
  #   to ask for some (feedback still waiting to be placed)
  def initialize(item:, suggestions:, cells: {}, can_regenerate: false, offer_when_empty: false)
    @item = item
    @suggestions = suggestions
    @cells = cells
    @can_regenerate = can_regenerate
    @offer_when_empty = offer_when_empty
  end


  def view_template
    div(id: self.class.dom_id_for(@item.id), data: { testid: "placement-suggestions" }) do
      if @suggestions.any?
        suggestion_list
      elsif @can_regenerate && @offer_when_empty
        div(class: "pt-1") { regenerate_button("Suggest where this belongs") }
      end
    end
  end

  private

  def suggestion_list
    render Components::Kit::Card.new(variant: :inset, density: :compact, class: "mt-2") do |card|
      card.body do
        div(class: "space-y-3") do
          div(class: "flex flex-wrap items-baseline justify-between gap-2") do
            h4(class: "text-xs font-semibold uppercase tracking-wide text-muted") { "Suggested placements" }
            p(class: "text-xs text-muted") { "Suggested by an AI model from the feedback. Nothing is placed until you accept." }
          end
          ul(class: "space-y-3", role: "list") { @suggestions.each { |suggestion| row(suggestion) } }
          div(class: "flex flex-wrap items-center gap-x-4 border-t border-default pt-2") do
            button(type: "button", data: adjust_trigger_data, class: LINK_BTN) { "Adjust in the editor" }
            regenerate_button("Suggest again") if @can_regenerate
          end
        end
      end
    end
  end

  def row(suggestion)
    cell = @cells.fetch(suggestion.id, {})
    li(id: "evidence-suggestion-#{suggestion.id}", class: "space-y-1", data: { suggestion_id: suggestion.id }) do
      div(class: "flex flex-wrap items-center gap-x-2 gap-y-1") do
        span(class: "text-sm font-medium text-default") do
          [ cell[:name] || "Capability", cell[:level_code].presence || "L#{suggestion.level_ordinal}" ].join(" · ")
        end
        valence_badge(suggestion.valence)
        span(class: "text-xs text-muted") { "#{(suggestion.confidence.to_f * 100).round}% confident" }
      end
      p(class: "text-xs text-muted") { "↳ #{cell[:expectation]}" } if cell[:expectation].present?
      p(class: "text-sm text-default") { suggestion.rationale } if suggestion.rationale.present?
      actions(suggestion, cell)
    end
  end

  def actions(suggestion, cell)
    label = [ cell[:name], cell[:level_code] ].compact.join(" ")
    div(class: "flex flex-wrap items-start gap-x-3 gap-y-1") do
      form_with(url: accept_evidence_placement_suggestion_path(suggestion), method: :post,
                data: { turbo_stream: true }) do
        render Components::Kit::Button.new(type: :submit, touch: true, aria: { label: "Accept: #{label}" },
                                           data: { turbo_submits_with: "Accepting…" }) { "Accept" }
      end
      dismiss_disclosure(suggestion, label)
    end
  end

  # A disclosure rather than a modal: the reason is optional and short, and
  # the row it belongs to stays in view.
  def dismiss_disclosure(suggestion, label)
    details(class: "group") do
      summary(class: "#{Components::Kit::Button.classes(variant: :link, tone: :neutral, touch: true)} " \
                     "list-none [&::-webkit-details-marker]:hidden",
              aria: { label: "Dismiss: #{label}" }) { "Dismiss…" }
      form_with(url: dismiss_evidence_placement_suggestion_path(suggestion), method: :post,
                data: { turbo_stream: true }, class: "mt-1 flex flex-wrap items-end gap-2") do
        div(class: "min-w-56 flex-1") do
          label(for: "dismiss-reason-#{suggestion.id}", class: "block text-xs font-medium text-muted mb-1") do
            "Why not? (optional)"
          end
          input(type: "text", id: "dismiss-reason-#{suggestion.id}", name: "reason", class: Components::Kit::Field::INPUT,
                maxlength: 500)
        end
        button(type: "submit", class: Components::Shared::FrameLoadError::BUTTON_CLASSES) { "Dismiss" }
      end
    end
  end

  def regenerate_button(text)
    form_with(url: evidence_item_placement_suggestions_path(@item), method: :post, data: { turbo_stream: true }) do
      button(type: "submit", class: LINK_BTN, data: { turbo_submits_with: "Asking…" }) { text }
    end
  end

  # Opens the shared evidence modal on this item, with the pending
  # suggestions staged as rows (EvidenceModalController reads `suggestions`).
  def adjust_trigger_data
    {
      action: "evidence-modal#load click->modal#open",
      modal_target_id: "evidence-modal-overlay",
      evidence_modal_mode_param: "edit",
      evidence_modal_evidence_id_param: @item.id,
      evidence_modal_suggestions_param: "pending",
      evidence_modal_return_to_param: "hub"
    }
  end
end
