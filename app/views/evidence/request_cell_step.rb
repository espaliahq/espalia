# frozen_string_literal: true

# The request modal's first step when it opens without a cell, as a
# conversation's "Ask Jordan for feedback" does: requests are about one
# capability at one level, so the asker picks those first. Submitting loads
# the ordinary request form into the same frame, with the person to ask
# already picked.
class Views::Evidence::RequestCellStep < Views::Base
  LABEL = "block text-xs font-medium text-muted mb-1"

  # @param form_url [String] the modal endpoint the step submits to
  # @param capabilities [Array<Hash>] [{ category_name:, capabilities: [{ stable_id:, name: }] }]
  # @param levels [Array<Hash>] [{ ordinal:, label: }]
  # @param current_level [Integer, nil] the assessee's level, chosen to start with
  # @param assessee [Person, nil] whom the request is about, when not the asker
  # @param requestee [Person, nil] whom to ask, when already known
  def initialize(form_url:, capabilities:, levels:, current_level:, assessee: nil, requestee: nil)
    @form_url = form_url
    @capabilities = capabilities
    @levels = levels
    @current_level = current_level
    @assessee = assessee
    @requestee = requestee
  end

  def view_template
    turbo_frame_tag("evidence-request-modal") do
      div(class: "p-5", data: { testid: "request-cell-step" }) do
        div(class: "flex items-start justify-between mb-3") do
          h2(class: "text-base font-semibold text-default") { title }
          render Components::Kit::Button.new(variant: :ghost, icon: true, aria_label: "Close",
                                             data: { action: "modal#close" }) { "×" }
        end
        p(class: "mb-4 text-sm text-muted") { "Requests are about one capability at one level. Which should they speak to?" }
        form(action: @form_url, method: "get", class: "space-y-4") do
          input(type: "hidden", name: "requestee_id", value: @requestee.id) if @requestee
          div do
            label(for: "request-cell-capability", class: LABEL) { "Capability" }
            select(id: "request-cell-capability", name: "capability_stable_id", required: true, class: Components::Kit::Field::SELECT) do
              @capabilities.each do |group|
                optgroup(label: group[:category_name]) do
                  group[:capabilities].each { |cap| option(value: cap[:stable_id]) { cap[:name] } }
                end
              end
            end
          end
          div do
            label(for: "request-cell-level", class: LABEL) { "Level" }
            select(id: "request-cell-level", name: "level_ordinal", class: Components::Kit::Field::SELECT) do
              @levels.each do |level|
                option(value: level[:ordinal], selected: level[:ordinal] == @current_level) { level[:label] }
              end
            end
          end
          div(class: "flex items-center justify-end gap-2 pt-2") do
            render Components::Kit::Button.new(variant: :outline, touch: true, data: { action: "modal#close" }) { "Cancel" }
            render Components::Kit::Button.new(tone: :brand, touch: true, type: :submit) { "Next" }
          end
        end
      end
    end
  end

  private

  def title
    whom = @requestee ? "Ask #{@requestee.name.to_s.split.first}" : "Ask someone"
    @assessee ? "#{whom} about #{@assessee.name.to_s.split.first}" : "#{whom} for feedback"
  end
end
