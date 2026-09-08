# frozen_string_literal: true

require "test_helper"

# The pending-expectation ghost. Pins the inline Approve/Reject kebab: present
# (and right-most, after the pencil) for a viewer whose authority clears the
# expectation tier, absent otherwise.
class Views::Frameworks::Explorer::PendingExpectationFrameTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @suggestion = create(:framework_suggested_edit,
      tenant: @tenant, target_entity_type: "behavioural_expectation",
      kind: "create", field: nil, suggested_value: nil,
      parent_id: SecureRandom.uuid_v7,
      proposed_attributes: { "level_ordinal" => 2, "description" => "Proposed expectation text" })
  end

  teardown { ActsAsTenant.current_tenant = nil }

  # Through a real view context — the frame renders route helpers + an
  # authenticity token.
  def view_context
    @view_context ||= ApplicationController.new
      .tap { |controller| controller.request = ActionDispatch::TestRequest.create }
      .view_context
  end

  # @param authority [Frameworks::SuggestionApprovalAuthority]
  # @return [String] the rendered frame HTML
  def render_frame(authority)
    view_context.render(Views::Frameworks::Explorer::PendingExpectationFrame.new(
      suggestion: @suggestion, framework_id: SecureRandom.uuid_v7,
      level_ordinal: 2, approval_authority: authority
    ))
  end

  ALL_TIERS = Frameworks::SuggestionApprovalAuthority.new(
    tenant_admin: true, tier1: true, tier2: true, tier3: true
  )

  context "Views::Frameworks::Explorer::PendingExpectationFrame" do
    should "render the approval kebab for a viewer with expectation-tier authority" do
      html = render_frame(ALL_TIERS)
      # The menu itself is built client-side from the trigger's ids (#380), so
      # the server's contract is the kebab kind + the suggestion it names.
      assert_includes html, %(data-menu="expectation-create")
      assert_includes html, %(data-menu-sid="#{@suggestion.suggestion_id}")
      assert_includes html, "New-expectation suggestion actions"
      # Kebab is the right-most control — the pencil comes before the trigger.
      pencil = html.index("Amend suggestion") || html.index("Suggest alternative")
      trigger = html.index("New-expectation suggestion actions")
      assert pencil && trigger && pencil < trigger,
        "the pencil must precede the kebab trigger"
    end

    should "render no kebab without authority" do
      html = render_frame(Frameworks::SuggestionApprovalAuthority.none)
      assert_not_includes html, %(data-menu="expectation-create")
      assert_not_includes html, "New-expectation suggestion actions"
    end
  end
end
