# frozen_string_literal: true

# A stale membership or fact (#142): when it was last checked and by whom,
# and a "Still true" button for whoever may confirm it. The button confirms
# it as of today and comes back to the screen it was pressed on.
class Views::Tenant::OrgGraph::StaleFlag < Views::Base
  include Phlex::Rails::Helpers::Routes

  # @param ages [Array<OrgFactAge>] the stale facts behind one line, oldest first
  # @param person [Person]
  # @param subject [String] what is stale, for the button's name ("membership of Platform")
  # @param confirm [Boolean] whether to offer "Still true"
  # @param back_to [Hash] `return_to`, `unit` and `back` for the redirect
  def initialize(ages:, person:, subject:, confirm:, back_to: {})
    @ages = Array(ages)
    @person = person
    @subject = subject
    @confirm = confirm
    @back_to = back_to.compact
  end

  def render? = @ages.any?

  def view_template
    oldest = @ages.first
    div(class: "flex w-full flex-wrap items-center gap-x-2 gap-y-1", data: { stale_flag: @subject }) do
      render Components::Kit::Badge.new("Not confirmed since #{oldest.checked_at.strftime('%-d %b %Y')}", tone: :warning)
      span(class: "text-xs text-muted") { "Last checked by #{oldest.checked_by.name}." } if oldest.checked_by
      confirm_form if @confirm
    end
  end

  private

  def confirm_form
    form(action: tenant_org_person_confirmations_path(@person), method: "post") do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      @ages.each do |age|
        input(type: "hidden", name: "facts[]", value: age.fact)
      end
      input(type: "hidden", name: "unit_id", value: @ages.first.unit_id) if @ages.first.membership?
      @back_to.each { |name, value| input(type: "hidden", name: name.to_s, value:) }
      render Components::Kit::Button.new(variant: :outline, size: :sm, type: :submit, compact: true,
                                         aria_label: "Confirm #{@subject} is still true") { "Still true" }
    end
  end
end
