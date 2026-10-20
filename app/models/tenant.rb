# frozen_string_literal: true

# Represents an organisation using GrowthOS.
#
# Tenants are the root of the multi-tenancy model. All user and domain data
# is scoped to a tenant via acts_as_tenant row-level isolation.
#
# @example
#   tenant = Tenant.create!(name: "ACME Corp", slug: "acme-corp")
#
class Tenant < ApplicationRecord
  include Themeable

  has_many :tenant_users, dependent: :destroy
  has_many :users, through: :tenant_users
  has_many :people, dependent: :destroy

  attribute :hris_config, HrisConfig.to_type, default: -> { HrisConfig.new }
  serialize :hris_credentials, coder: JSON
  encrypts :hris_credentials

  # Slack bot credentials for this workspace, set when a tenant admin installs
  # the GrowthOS Slack app. Encrypted JSON: { bot_token:, team_name:, installed_by: }.
  serialize :slack_credentials, coder: JSON
  encrypts :slack_credentials

  # The word this tenant uses for each performance state. The state itself
  # is scoring policy and stays internal; the word is culture (#415). A
  # blank value falls back to the shipped default — see
  # {Views::Assessments::StateLabels}, the one reader.
  STATE_LABEL_ATTRIBUTES = %i[
    underperforming_label progressing_label performing_label mastering_label eligible_label
  ].freeze

  # Long enough for "Exceeding expectations", short enough to stay a badge:
  # every surface renders these as an eyebrow beside a number, never in the
  # middle of a sentence.
  STATE_LABEL_MAX_LENGTH = 24

  translates(*STATE_LABEL_ATTRIBUTES)

  # `normalizes` only reaches real AR attributes, and json_translate's are
  # methods over a jsonb column — so the strip is a callback. Without it a
  # label of spaces is neither blank (the fallback never fires) nor a word
  # (it renders as an empty badge).
  before_validation :strip_state_labels

  normalizes :slug, with: ->(s) { s.downcase.strip.gsub(/[^a-z0-9-]/, "-").gsub(/-+/, "-").delete_prefix("-").delete_suffix("-") }


  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true,
    format: { with: /\A[a-z0-9-]+\z/, message: "must contain only lowercase letters, numbers, and dashes" }
  validates(*STATE_LABEL_ATTRIBUTES, length: { maximum: STATE_LABEL_MAX_LENGTH }, allow_blank: true)
  validates :hris_config, store_model: true

  # @return [Boolean] whether this tenant has a usable Slack connection
  def slack_connected?
    slack_bot_token.present?
  end

  # @return [String, nil] the Slack bot token, or nil when not connected
  def slack_bot_token
    slack_credentials.is_a?(Hash) ? slack_credentials["bot_token"].presence : nil
  end

  # @return [String, nil] the connected workspace's display name
  def slack_team_name
    slack_credentials.is_a?(Hash) ? slack_credentials["team_name"] : nil
  end

  # Record a completed Slack install. Persists the encrypted bot token and the
  # plain team id (used for inbound event routing later).
  #
  # @param bot_token [String]
  # @param team_id [String]
  # @param team_name [String, nil]
  # @param installed_by [String, nil] Person id of the installing admin
  # @return [Boolean]
  def connect_slack!(bot_token:, team_id:, team_name: nil, installed_by: nil)
    transaction do
      update!(
        slack_team_id: team_id,
        slack_credentials: { "bot_token" => bot_token, "team_name" => team_name, "installed_by" => installed_by }
      )
      # A reconnect may point at a different workspace, where the cached
      # per-user Slack ids no longer resolve — clear them so they re-resolve.
      tenant_users.where.not(slack_user_id: nil).update_all(slack_user_id: nil)
    end
    true
  end

  # Remove the Slack connection. Cached per-user Slack ids are cleared too so a
  # reconnect to a different workspace re-resolves identities.
  #
  # @return [void]
  def disconnect_slack!
    transaction do
      update!(slack_credentials: nil, slack_team_id: nil)
      tenant_users.where.not(slack_user_id: nil).update_all(slack_user_id: nil)
    end
  end

  private

  # @return [void]
  def strip_state_labels
    STATE_LABEL_ATTRIBUTES.each do |attribute|
      value = public_send(attribute)
      next unless value.is_a?(String) && value != value.strip

      public_send(:"#{attribute}=", value.strip)
    end
  end
end
