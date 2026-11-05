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

    # The job has no ambient tenant; the blocks below name the product by this one.
    @tenant = tenant

    slack_user_id = resolve_slack_user_id(tenant)
    return if slack_user_id.blank?

    disclose = disclose_preferences?
    Slack::Client.new(bot_token: tenant.slack_bot_token)
      .post_dm(slack_user_id: slack_user_id, text: message_text,
               blocks: message_blocks(disclose_preferences: disclose))
    mark_preferences_disclosed if disclose
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
  # when an absolute URL can be built, and — on the recipient's first-ever
  # external DM — the one-time preferences disclosure footer.
  def message_blocks(disclose_preferences: false)
    blocks = [ { type: "section", text: { type: "mrkdwn", text: "*#{mrkdwn_escape(notification.inbox_title)}*" } } ]
    body = notification.inbox_body
    blocks << { type: "section", text: { type: "mrkdwn", text: mrkdwn_escape(body) } } if body.present?

    url = absolute_url(notification.inbox_url)
    if url
      blocks << {
        type: "actions",
        elements: [ { type: "button", text: { type: "plain_text", text: "Open in #{product_name}" }, url: url } ]
      }
    end
    blocks << preferences_footer if disclose_preferences
    blocks
  end

  # Whether this DM should carry the one-time preferences disclosure: the
  # recipient has never had one. Persisted on the User (a fact, not inferred
  # from notification timestamps — those tie under load and in frozen-time
  # tests) and marked only AFTER a successful post, so a failed or skipped
  # delivery keeps the disclosure for the recipient's next DM. A concurrent
  # double-disclosure in that window is possible and harmless.
  #
  # @return [Boolean]
  def disclose_preferences?
    recipient.respond_to?(:external_notifications_disclosed_at) &&
      recipient.external_notifications_disclosed_at.nil?
  end

  def mark_preferences_disclosed
    recipient.update_column(:external_notifications_disclosed_at, Time.current)
  end

  # One-time orientation footer for a first DM: disclose the in-app-first
  # delivery model and where to tune what reaches Slack. Our own copy — not
  # user text — so the deliberate mrkdwn link is not escaped.
  def preferences_footer
    url = absolute_url("/settings/notifications")
    prefs = url ? "<#{url}|notification preferences>" : "notification preferences (Settings → Notifications)"
    {
      type: "context",
      elements: [ {
        type: "mrkdwn",
        text: "👋 First time hearing from #{product_name}? Notifications arrive in the app first — " \
              "Slack only chimes in when you haven't seen them there. " \
              "Choose what reaches you, and where, in your #{prefs}."
      } ]
    }
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

  def product_name
    @tenant&.product_name || Tenant.current_product_name
  end
end
