# frozen_string_literal: true

# Noticed delivery method that DMs a notification to the recipient over the
# tenant's Slack workspace. Wired by ApplicationNotifier as
# `deliver_by :slack, class: "SlackDeliveryMethod"`.
#
# Slack is installed per tenant, so the notifier must carry `tenant_id` in its
# params. Delivery is best-effort: a missing connection, an unmatched user, or
# an API error logs and returns rather than raising (which would retry the job
# indefinitely). The escalation gate (wait + unread check) lives on the
# notifier's `config.if`/`config.wait`, so by the time this runs we already
# know the recipient should be pinged.
class SlackDeliveryMethod < Noticed::DeliveryMethod
  def deliver
    tenant = Tenant.find_by(id: event.params[:tenant_id])
    return unless tenant&.slack_connected?

    slack_user_id = resolve_slack_user_id(tenant)
    return if slack_user_id.blank?

    Slack::Client.new(bot_token: tenant.slack_bot_token)
      .post_dm(slack_user_id: slack_user_id, text: message_text, blocks: message_blocks)
  rescue Slack::Errors::Error => e
    Rails.logger.warn("[slack] delivery skipped (tenant=#{tenant&.id}): #{e.class}: #{e.message}")
  end

  private

  # Find (and cache) the recipient's Slack user id within the tenant workspace.
  # Looks up by their Person email first, falling back to the User email.
  #
  # @return [String, nil]
  def resolve_slack_user_id(tenant)
    membership = ActsAsTenant.with_tenant(tenant) do
      TenantUser.find_by(user_id: recipient.id)
    end
    return nil if membership.nil?
    return membership.slack_user_id if membership.slack_user_id.present?

    email = membership.person&.email.presence || recipient.email
    return nil if email.blank?

    id = Slack::Client.new(bot_token: tenant.slack_bot_token).lookup_user_id_by_email(email)
    membership.update_column(:slack_user_id, id) if id.present?
    id
  end

  def message_text
    [ notification.inbox_title, notification.inbox_body ].compact
      .map { |part| mrkdwn_escape(part) }.join(" — ")
  end

  # Block Kit payload: the headline + body, then a button to the in-app surface
  # when an absolute URL can be built.
  def message_blocks
    blocks = [ { type: "section", text: { type: "mrkdwn", text: "*#{mrkdwn_escape(notification.inbox_title)}*" } } ]
    body = notification.inbox_body
    blocks << { type: "section", text: { type: "mrkdwn", text: mrkdwn_escape(body) } } if body.present?

    url = absolute_url(notification.inbox_url)
    if url
      blocks << {
        type: "actions",
        elements: [ { type: "button", text: { type: "plain_text", text: "Open in GrowthOS" }, url: url } ]
      }
    end
    blocks
  end

  # Notification titles and bodies carry user-written free text (a request
  # message, a decline reason, a quoted evidence response). Slack parses both
  # the `text` fallback and mrkdwn section blocks for control sequences, so
  # `<https://evil.example|innocent label>` or `<!channel>` typed by a user
  # would render as a masked link / broadcast. Escape the three control
  # characters per Slack's "Escaping text" rules; styling chars (*_~) are
  # deliberately left alone — cosmetic at worst.
  #
  # @param text [String]
  # @return [String]
  def mrkdwn_escape(text)
    text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end

  # @return [String, nil] absolute URL for a relative app path, or nil when no
  #   host is configured (then the Slack message carries text only).
  def absolute_url(path)
    return nil if path.blank?
    return path if path.start_with?("http")

    host = Rails.application.config.action_mailer.default_url_options&.dig(:host)
    return nil if host.blank?

    scheme = Rails.env.production? ? "https" : "http"
    port = Rails.application.config.action_mailer.default_url_options[:port]
    base = port ? "#{scheme}://#{host}:#{port}" : "#{scheme}://#{host}"
    "#{base}#{path}"
  end
end
