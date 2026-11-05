# frozen_string_literal: true

# What the two inbound Slack controllers share for giving feedback: opening
# the modal, turning a submission into the evidence write (as the giver,
# through the same Operation the web and MCP use), the draft-and-link path
# for a giver who has never signed in, and the DMs that close each loop.
module Slack::Feedback
  MESSAGE_SHORTCUT = "give_feedback_on_message"

  Result = Struct.new(:errors, :evidence_id, :draft, keyword_init: true)

  module_function

  # @param identity [Slack::Identity] a member
  # @param trigger_id [String]
  def open_modal(identity, trigger_id:, initial_content: nil, external_url: nil)
    framework = ActsAsTenant.with_tenant(identity.tenant) { FrameworkState::Framework.first }
    view = Slack::FeedbackModal.view(framework: framework, initial_content: initial_content, external_url: external_url)
    client(identity.tenant).open_view(trigger_id: trigger_id, view: view)
  end

  # @param identity [Slack::Identity]
  # @param fields [Hash] from {Slack::FeedbackModal.read}
  # @return [Result]
  def submit(identity, fields)
    errors = validate(fields)
    return Result.new(errors: errors) if errors.any?

    ActsAsTenant.with_tenant(identity.tenant) do
      if identity.member?
        record(identity, fields)
      elsif identity.person_only?
        draft(identity, fields)
      else
        Result.new(errors: { Slack::FeedbackModal::BLOCKS[:content] => "No #{product_name} account matches your Slack email." })
      end
    end
  end

  def validate(fields)
    errors = {}
    errors[Slack::FeedbackModal::BLOCKS[:recipient]] = "Pick who the feedback is for." if fields[:assignment_id].blank?
    errors[Slack::FeedbackModal::BLOCKS[:content]] = "Say what happened." if fields[:content].blank?
    if fields[:capability_stable_id].present? && fields[:valence].blank?
      errors[Slack::FeedbackModal::BLOCKS[:valence]] = "Say what it shows about that capability, or leave both blank."
    end
    errors
  end

  # Record as the giver. A capability is placed at the recipient's current
  # level; a cell the role has no expectation at comes back as a form error
  # rather than a failed write.
  def record(identity, fields)
    assignment = PersonFrameworkAssignment.find_by(id: fields[:assignment_id])
    return Result.new(errors: { Slack::FeedbackModal::BLOCKS[:recipient] => "That person no longer has an assessment." }) if assignment.nil?

    params = { assignment_id: assignment.id, evidence_type: fields[:evidence_type], content: fields[:content] }
    params[:external_reference] = { system: "slack", url: fields[:external_url] } if fields[:external_url].present?
    if fields[:capability_stable_id].present?
      level = assignment.level&.ordinal
      unless cell_exists?(assignment, fields[:capability_stable_id], level)
        return Result.new(errors: { Slack::FeedbackModal::BLOCKS[:capability] =>
          "That capability has no expectation at their level — pick another, or leave it blank." })
      end
      params.merge!(capability_stable_id: fields[:capability_stable_id], level_ordinal: level, valence: fields[:valence])
    end

    result = AuditMetadata.with(acting_via: :slack, actor_id: identity.person.id, correlation_id: SecureRandom.uuid) do
      Operations::Assessments::RecordEvidence.call(context: identity.authorization_context, params: params)
    end
    confirm(identity, assignment, placed: result[:placed])
    Result.new(errors: {}, evidence_id: result[:evidence_id])
  rescue Operations::Base::ParameterError => e
    Result.new(errors: { Slack::FeedbackModal::BLOCKS[:capability] => e.message })
  rescue Pundit::NotAuthorizedError
    Result.new(errors: { Slack::FeedbackModal::BLOCKS[:recipient] => "You can't give feedback on that assessment." })
  end

  # The web picker offers only cells with an expectation; the modal's list is
  # the whole framework, so the check happens here before the write.
  def cell_exists?(assignment, capability_stable_id, level_ordinal)
    return false if level_ordinal.nil?

    Evidence::FrameworkCellOptions.new(framework_id: assignment.framework_id, role_id: assignment.role_id)
      .expectation_map.key?("#{capability_stable_id}|#{level_ordinal}")
  end

  # Keep the submission and send a link: the first sign-in lands on the hub
  # with the modal filled from it. The capability is not kept — the web form
  # offers the full picker.
  def draft(identity, fields)
    assignment = PersonFrameworkAssignment.find_by(id: fields[:assignment_id])
    draft = FeedbackDraft.create!(
      tenant: identity.tenant, author_email: identity.email,
      recipient_person_id: assignment&.person_id, assignment_id: assignment&.id,
      content: fields[:content], evidence_type: fields[:evidence_type],
      external_reference: (fields[:external_url].present? ? { system: "slack", url: fields[:external_url] } : {})
    )
    dm(identity.tenant, nil, "Your feedback is saved. Sign in to #{product_name} to send it: #{absolute_url(draft.path)}",
       email: identity.email, url: absolute_url(draft.path), button: "Sign in and send")
    Result.new(errors: {}, draft: draft)
  end

  def not_a_member_message(identity)
    # Called from the inbound controllers, outside any ambient tenant —
    # the identity's tenant carries the name its workspace knows.
    "No #{product_name(identity&.tenant)} account matches your Slack email. Ask a workspace admin to add you."
  end

  def confirm(identity, assignment, placed:)
    name = Person.where(id: assignment.person_id).pick(:name) || "them"
    text = placed ? "Feedback for #{name} recorded." : "Feedback for #{name} recorded — not yet placed on a capability; they or their manager can place it."
    dm(identity.tenant, identity.tenant_user.slack_user_id, text, url: absolute_url("/evidence"), button: "Open in #{product_name}")
  end

  # A DM, by Slack user id or by email, with an optional button — queued, so
  # the inbound request answers inside Slack's window whatever Slack's own
  # API latency is.
  def dm(tenant, slack_user_id, text, email: nil, url: nil, button: nil)
    Slack::DmJob.perform_later(tenant.id, slack_user_id, text, email: email, url: url, button: button)
  end

  # The DM itself, from the job. Best effort.
  def deliver_dm(tenant, slack_user_id, text, email: nil, url: nil, button: nil)
    slack_client = client(tenant)
    slack_user_id ||= slack_client.lookup_user_id_by_email(email) if email.present?
    return if slack_user_id.blank?

    blocks = [ { type: "section", text: { type: "mrkdwn", text: text } } ]
    blocks << { type: "actions", elements: [ { type: "button", text: { type: "plain_text", text: button }, url: url } ] } if url && button
    slack_client.post_dm(slack_user_id: slack_user_id, text: text, blocks: blocks)
  rescue Slack::Errors::Error => e
    Rails.logger.warn("[slack] dm skipped (tenant=#{tenant.id}): #{e.class}: #{e.message}")
  end

  def permalink(tenant, channel:, message_ts:)
    return nil if channel.blank? || message_ts.blank?

    client(tenant).permalink(channel: channel, message_ts: message_ts)
  end

  def absolute_url(path)
    host = Rails.application.routes.default_url_options[:host] || Rails.application.config.x.oauth_issuer
    host.present? ? URI.join(host, path).to_s : path
  end

  def client(tenant)
    Slack::Client.new(bot_token: tenant.slack_bot_token)
  end

  # @param tenant [Tenant, nil] pass the identity's tenant where no ambient
  #   tenant context is set (the inbound Slack controllers)
  def product_name(tenant = nil)
    Slack.escape_text(tenant&.product_name || Tenant.current_product_name)
  end
end
