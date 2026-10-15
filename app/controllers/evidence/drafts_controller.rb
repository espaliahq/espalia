# frozen_string_literal: true

# The link a Slack draft DM carries (GET /evidence/drafts/:token). Signing in
# is required, and Devise stores this path on the way to the sign-in page, so
# the author lands back here afterwards — then on the hub with the modal
# already filled from the draft. Only a session for the draft's own email
# may open it.
class Evidence::DraftsController < ApplicationController
  # GET /evidence/drafts/:token
  def show
    draft = ActsAsTenant.without_tenant { FeedbackDraft.open.find_by(token: params[:token]) }
    return redirect_to evidence_hub_path, alert: "That feedback link has expired or was already used." if draft.nil?
    return redirect_to evidence_hub_path, alert: "That feedback link belongs to another account." unless owns?(draft)

    authorize draft, :show?, policy_class: FeedbackDraftPolicy
    session[:current_tenant_id] = draft.tenant_id
    redirect_to evidence_hub_path(draft: draft.token)
  end

  private

  def owns?(draft)
    current_user.email.to_s.strip.casecmp?(draft.author_email)
  end
end
