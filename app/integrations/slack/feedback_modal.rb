# frozen_string_literal: true

# The "Give feedback" Slack modal: its Block Kit view, and the reading of a
# submission back into the arguments the evidence Operations take. One class
# so the block ids written here are the ones read here.
#
# Recipient is an external_select the interactions endpoint feeds from the
# recipient directory; capability and valence are optional, and a capability
# alone means "at the recipient's current level" — the phone-sized modal has
# no room for a level ladder, and placing can be left to the recipient anyway
# (an unplaced item, exactly as on the web).
class Slack::FeedbackModal
  CALLBACK_ID = "give_feedback"
  RECIPIENT_ACTION = "recipient"
  MAX_OPTIONS = 100

  BLOCKS = {
    recipient: "recipient_block", content: "content_block", type: "type_block",
    capability: "capability_block", valence: "valence_block"
  }.freeze

  TYPE_LABELS = Views::Evidence::ModalForm::TYPE_OPTIONS.to_h { |text, value| [ value, text ] }.freeze

  # @param framework [FrameworkState::Framework, nil] whose capabilities to offer
  # @param initial_content [String, nil] prefilled text (a message shortcut)
  # @param external_url [String, nil] the message permalink, kept in private_metadata
  # @return [Hash] a `views.open` view payload
  def self.view(framework:, initial_content: nil, external_url: nil)
    new(framework: framework).view(initial_content: initial_content, external_url: external_url)
  end

  # @param framework [FrameworkState::Framework, nil]
  def initialize(framework:)
    @framework = framework
  end

  # @return [Hash]
  def view(initial_content: nil, external_url: nil)
    {
      type: "modal", callback_id: CALLBACK_ID,
      private_metadata: { external_url: external_url }.compact.to_json,
      title: { type: "plain_text", text: "Give feedback" },
      submit: { type: "plain_text", text: "Give feedback" },
      close: { type: "plain_text", text: "Cancel" },
      blocks: [
        recipient_block, content_block(initial_content), type_block,
        *capability_blocks, context_block
      ]
    }
  end

  # The submitted values, as the evidence write wants them.
  #
  # @param view [Hash] the `view` of a view_submission payload
  # @return [Hash] `{ assignment_id:, content:, evidence_type:, capability_stable_id:, valence:, external_url: }`
  def self.read(view)
    values = view.fetch("state").fetch("values")
    pick = ->(block, action = nil) { values.dig(block, action || block) || {} }
    {
      assignment_id: pick.(BLOCKS[:recipient], RECIPIENT_ACTION).dig("selected_option", "value"),
      content: pick.(BLOCKS[:content])["value"].to_s.strip,
      evidence_type: pick.(BLOCKS[:type]).dig("selected_option", "value") || "peer_feedback",
      capability_stable_id: pick.(BLOCKS[:capability]).dig("selected_option", "value").presence,
      valence: pick.(BLOCKS[:valence]).dig("selected_option", "value").presence,
      external_url: (JSON.parse(view["private_metadata"].presence || "{}")["external_url"] rescue nil)
    }
  end

  # Options for the recipient external_select, from the directory.
  #
  # @param recipients [Array<Assessments::FeedbackRecipients::Recipient>]
  # @return [Hash] a `block_suggestion` response
  def self.recipient_options(recipients)
    {
      options: recipients.first(MAX_OPTIONS).map do |r|
        description = [ r.assignment.role&.name, r.assignment.level&.code ].compact.join(" · ")
        option = { text: { type: "plain_text", text: r.person.name.truncate(75) }, value: r.assignment.id }
        option[:description] = { type: "plain_text", text: description.truncate(75) } if description.present?
        option
      end
    }
  end

  private

  def recipient_block
    {
      type: "input", block_id: BLOCKS[:recipient],
      label: { type: "plain_text", text: "Who is it for?" },
      element: {
        type: "external_select", action_id: RECIPIENT_ACTION, min_query_length: 1,
        placeholder: { type: "plain_text", text: "Search by name or email" }
      }
    }
  end

  def content_block(initial)
    element = {
      type: "plain_text_input", action_id: BLOCKS[:content], multiline: true, max_length: 3000,
      placeholder: { type: "plain_text", text: "What happened?" }
    }
    element[:initial_value] = initial.to_s.truncate(3000) if initial.present?
    { type: "input", block_id: BLOCKS[:content], label: { type: "plain_text", text: "What happened?" }, element: element }
  end

  def type_block
    options = TYPE_LABELS.map { |value, text| { text: { type: "plain_text", text: text }, value: value } }
    {
      type: "input", block_id: BLOCKS[:type], optional: true,
      label: { type: "plain_text", text: "Type" },
      element: {
        type: "static_select", action_id: BLOCKS[:type], options: options,
        initial_option: options.find { |o| o[:value] == "peer_feedback" }
      }
    }
  end

  # Capability plus valence, offered only when the framework has capabilities
  # to offer. Both optional: left blank, the item is recorded unplaced.
  def capability_blocks
    groups = capability_option_groups
    return [] if groups.empty?

    [
      {
        type: "input", block_id: BLOCKS[:capability], optional: true,
        label: { type: "plain_text", text: "Capability (optional — at their current level)" },
        element: { type: "static_select", action_id: BLOCKS[:capability], option_groups: groups,
                   placeholder: { type: "plain_text", text: "Leave blank and they can place it" } }
      },
      {
        type: "input", block_id: BLOCKS[:valence], optional: true,
        label: { type: "plain_text", text: "What does it say about that capability?" },
        element: {
          type: "static_select", action_id: BLOCKS[:valence],
          options: Views::Evidence::Valence::OPTIONS.map { |text, value| { text: { type: "plain_text", text: text }, value: value } },
          placeholder: { type: "plain_text", text: "Needed only with a capability" }
        }
      }
    ]
  end

  def capability_option_groups
    return [] if @framework.nil?

    budget = MAX_OPTIONS
    @framework.capability_categories.includes(:capabilities).order(:ordinal).filter_map do |category|
      caps = category.capabilities.active.order(:ordinal, :created_at).first(budget)
      budget -= caps.size
      next if caps.empty?

      { label: { type: "plain_text", text: category.name.truncate(75) },
        options: caps.map { |c| { text: { type: "plain_text", text: c.name.truncate(75) }, value: c.stable_id } } }
    end
  end

  def context_block
    { type: "context", elements: [ { type: "mrkdwn",
      text: "Visible to the person, their managers and workspace admins. Not sure which capability? Leave it blank — they or their manager can place it." } ] }
  end
end
