# frozen_string_literal: true

# Sends one Slack DM off the request path. The inbound Slack endpoints must
# answer within three seconds, and a DM is two Slack calls that can each wait
# several; a slow DM must never hold a modal open long enough for Slack to
# retry the submission and duplicate the write. Best effort, like every DM.
class Slack::DmJob < ApplicationJob
  queue_as :default

  # @param tenant_id [String]
  # @param slack_user_id [String, nil] the recipient, or nil to resolve by email
  # @param text [String]
  # @param email [String, nil]
  # @param url [String, nil] a button's link
  # @param button [String, nil] the button's label
  def perform(tenant_id, slack_user_id, text, email: nil, url: nil, button: nil)
    tenant = Tenant.find_by(id: tenant_id)
    return if tenant.nil? || !tenant.slack_connected?

    Slack::Feedback.deliver_dm(tenant, slack_user_id, text, email: email, url: url, button: button)
  end
end
