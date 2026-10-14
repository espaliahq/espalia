# frozen_string_literal: true

# The decline dialog for one open incoming request, opened by the card's
# "Decline request" button. Embedded in the hub's `modal` controller beside the
# shared evidence modal, so its trigger names it by id.
class Views::Evidence::DeclineRequestModal < Views::Base
  include Phlex::Rails::Helpers::FormWith

  INPUT = "w-full rounded-md border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 " \
          "text-gray-900 dark:text-gray-100 text-sm focus-visible:ring-primary focus-visible:border-primary"

  # @param request [EvidenceRequest]
  def initialize(request:)
    @request = request
  end

  # @param request [EvidenceRequest]
  # @return [String] DOM id of the request's decline dialog
  def self.dom_id_for(request)
    "decline-request-modal-#{request.id}"
  end

  def view_template
    render Components::Kit::Modal.new(id: self.class.dom_id_for(@request), title: "Decline request",
                                      standalone: false, dirty_guard: "Discard your decline reason?") do |modal|
      modal.body { decline_form }
    end
  end

  private

  def decline_form
    form_with(url: decline_evidence_request_path(@request), method: :post, scope: :evidence_request, class: "space-y-4") do |f|
      div do
        f.label(:reason, "Reason for declining (optional)", for: reason_id,
                class: "block text-xs font-medium text-gray-700 dark:text-gray-200 mb-1")
        f.text_area(:reason, id: reason_id, rows: 4, class: INPUT)
      end
      div(class: "flex items-center justify-end gap-2") do
        button(type: "button", data: { action: "modal#close" }, class: Components::Kit::FrameLoadError::BUTTON_CLASSES) { "Cancel" }
        f.submit("Decline request",
                 class: "inline-flex items-center justify-center min-h-11 px-4 rounded-md bg-primary text-white " \
                        "text-sm font-medium hover:opacity-90 cursor-pointer")
      end
    end
  end

  def reason_id
    "decline-reason-#{@request.id}"
  end
end
