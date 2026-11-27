# frozen_string_literal: true

# Authentication identity for an Espalia user.
#
# User holds global Devise credentials. It is NOT tenant-scoped — the same
# User can belong to multiple tenants via TenantUser join records. Tenant
# context (role, linked Person) lives on TenantUser, not here.
#
# @example
#   user = User.new(email: "alice@example.com", password: "s3cr3t")
#
class User < ApplicationRecord
  include HasTypeId
  has_typeid :usr

  has_many :tenant_users, dependent: :destroy
  has_many :tenants, through: :tenant_users

  # In-app notifications addressed to this user (Noticed). The record is the
  # cross-channel anchor: it always exists and its read state drives the
  # smart-escalation gate, even when the user has the in-app channel disabled
  # (in which case it simply doesn't surface in the inbox).
  has_many :notifications, as: :recipient, class_name: "Noticed::Notification", dependent: :destroy

  COLOR_SCHEMES = { auto: "auto", light: "light", dark: "dark" }.freeze

  # Raised by a save that skips validation and changes `global_admin` without naming an allowed
  # source. A validated save fails on `global_admin_source` instead.
  class GlobalAdminSourceMissing < StandardError; end

  # Where the next change to `global_admin` comes from: one of
  # {GlobalAdminChange::RECORDABLE_SOURCES}. Cleared after every save, by a validation that finds
  # an error, and by one run while the flag is unchanged: name it just before the save it is for.
  #
  # @return [String, nil]
  attr_accessor :global_admin_source

  validates :global_admin_source, inclusion: { in: GlobalAdminChange::RECORDABLE_SOURCES },
                                  allow_blank: true, if: :will_save_change_to_global_admin?
  validates :global_admin_source, presence: {
    message: "must name where this change to global_admin comes from: one of " \
             "#{GlobalAdminChange::RECORDABLE_SOURCES.join(', ')} (console for a change made by hand)"
  }, if: :will_save_change_to_global_admin?

  # A source applies only to the attempt it was named for: one that leaves the flag alone, or
  # fails validation, uses it up, so a later change has to name its own.
  before_validation -> { self.global_admin_source = nil }, unless: :will_save_change_to_global_admin?
  after_validation -> { self.global_admin_source = nil }, if: -> { errors.any? }

  # `update_column(s)`, `update_all`, `insert_all`, `upsert_all` and raw SQL skip these; see docs/architecture/domain-models.md.
  before_save :require_global_admin_source, if: :will_save_change_to_global_admin?
  before_save :lock_global_admin, if: -> { persisted? && will_save_change_to_global_admin? }
  after_save :record_global_admin_change

  # Auto follows the operating system. Personal and cross-tenant: a tenant
  # can't lock it.
  enum :color_scheme, COLOR_SCHEMES, default: :auto, prefix: true, validate: true

  # Include default devise modules. :validatable is included because email
  # uniqueness is now global (no tenant scope on User).
  devise :database_authenticatable, :registerable,
    :recoverable, :rememberable, :validatable,
    :omniauthable, omniauth_providers: [ :google_oauth2 ]

  # @return [Boolean] whether this user has global admin privileges
  def global_admin?
    global_admin
  end

  # Drops a source named for a save that never reached the audit, such as one that failed validation.
  #
  # @return [User]
  def reload(*)
    super.tap { self.global_admin_source = nil }
  end

  # The value for `<html data-scheme>`: the explicit choice, or nil for Auto
  # so the page follows the operating system.
  #
  # @return [String, nil] "light", "dark" or nil
  def data_scheme
    color_scheme unless color_scheme_auto?
  end

  # Whether this user wants notifications of the given type delivered over the
  # given channel. Resolves the user's stored overrides against the
  # code-defined defaults in {NotificationType}.
  #
  # @param type_key [Symbol, String] a NotificationType key (e.g. :evidence_requested)
  # @param channel [Symbol, String] one of NotificationType::CHANNELS
  # @return [Boolean]
  def notifies_via?(type_key, channel)
    NotificationType.enabled?(notification_preferences, type_key, channel)
  end

  # Merge explicit channel overrides for one notification type into the stored
  # preferences and persist. Only known channels are written; values cast to
  # booleans. Used by the notification settings UI.
  #
  # @param type_key [Symbol, String]
  # @param channels [Hash{Symbol,String=>Boolean}] channel => enabled
  # @return [Boolean] whether the save succeeded
  def update_notification_preference(type_key, channels)
    return false unless NotificationType.exists?(type_key)

    bool = ActiveModel::Type::Boolean.new
    overrides = channels.to_h.each_with_object({}) do |(channel, enabled), acc|
      next unless NotificationType::CHANNELS.include?(channel.to_sym)

      acc[channel.to_s] = bool.cast(enabled) || false
    end

    # Merge at the channel level so updating one channel (or the settings UI,
    # which submits only the in-app/slack channels) doesn't drop a previously
    # set override on another channel (e.g. an email override set via MCP).
    existing = notification_preferences[type_key.to_s] || {}
    merged = notification_preferences.merge(type_key.to_s => existing.merge(overrides))
    update(notification_preferences: merged)
  end

  # Resolve a Google OmniAuth payload into a signed-in-able User.
  #
  # Returns either `[user, nil]` on success or `[nil, reason]` on refusal.
  # Reasons: `:email_unverified`, `:no_matching_account`, `:invalid_payload`.
  #
  # Provisioning rules (see docs/guidelines/authorization.md and the plan):
  # - Refuse unless Google reports the email as verified.
  # - Existing User by `provider/uid` → return as-is.
  # - Existing User by email → backfill `provider`/`uid`.
  # - No User but a Person matches across any tenant → create both User and
  #   the linking TenantUser so the new identity lands in a usable tenant.
  # - Otherwise refuse.
  #
  # @param auth [OmniAuth::AuthHash]
  # @return [Array(User, nil), Array(nil, Symbol)]
  def self.from_google_omniauth(auth)
    return [ nil, :invalid_payload ] if auth.blank? || auth.uid.blank? || auth.info&.email.blank?
    return [ nil, :email_unverified ] unless google_email_verified?(auth)

    email = auth.info.email.to_s.downcase

    by_provider = find_by(provider: auth.provider, uid: auth.uid)
    return [ by_provider, nil ] if by_provider

    by_email = find_by(email: email)
    if by_email
      by_email.update!(provider: auth.provider, uid: auth.uid) if by_email.provider.blank?
      return [ by_email, nil ]
    end

    person = ActsAsTenant.without_tenant do
      Person.where("LOWER(email) = ?", email).order(:created_at).first
    end
    return [ nil, :no_matching_account ] if person.nil?

    begin
      [ provision_from_person!(person, auth), nil ]
    rescue ActiveRecord::RecordNotUnique
      # A concurrent Google sign-in for the same email won the race;
      # re-resolve and link instead of failing.
      from_google_omniauth(auth)
    end
  end

  def self.google_email_verified?(auth)
    info_flag = auth.info["email_verified"] if auth.info.respond_to?(:[])
    raw_flag = auth.extra&.raw_info&.[]("email_verified") || auth.extra&.raw_info&.email_verified
    [ info_flag, raw_flag ].any? { |f| f == true || f == "true" }
  end

  def self.provision_from_person!(person, auth)
    transaction do
      user = create!(
        email: auth.info.email.to_s.downcase,
        password: SecureRandom.hex(24),
        provider: auth.provider,
        uid: auth.uid
      )
      ActsAsTenant.with_tenant(person.tenant) do
        account = TenantUser.create!(tenant: person.tenant, user: user, role: :member)
        link_provisioned(account, person)
        AccountGrants::CommandHandler.new.record_new_account(account)
      end
      user
    end
  end

  # A refused link writes nothing, so the account is created unlinked and
  # sign-in goes ahead; its person stays with whoever holds them.
  def self.link_provisioned(account, person)
    account.link_to!(person, match: :provisioned)
  rescue AccountGrants::Aggregate::LinkRefused => e
    Rails.logger.warn("provisioned TenantUser #{account.id} left unlinked: #{e.class}")
  end

  private_class_method :google_email_verified?, :provision_from_person!, :link_provisioned

  private

  # For a save that skips validation. Holds the source to the list the audit row accepts, before the
  # write, so the row can't fail after the flag is written and leave an outer transaction to commit it.
  def require_global_admin_source
    return if GlobalAdminChange::RECORDABLE_SOURCES.include?(global_admin_source)

    if global_admin_source.present?
      raise GlobalAdminSourceMissing,
            "#{global_admin_source.inspect} is not a source the audit records: set global_admin_source to one of " \
            "#{GlobalAdminChange::RECORDABLE_SOURCES.join(', ')} before saving (console for a change made by hand)."
    end

    raise GlobalAdminSourceMissing,
          "Name where this change to global_admin comes from: set global_admin_source to one of " \
          "#{GlobalAdminChange::RECORDABLE_SOURCES.join(', ')} before saving (console for a change made by hand)."
  end

  # A copy loaded before another save changed the flag still sees its own change. Locking the row
  # until commit makes a second writer wait and read the flag the first one wrote.
  def lock_global_admin
    @global_admin_stored = self.class.where(id:).lock.pick(:global_admin)
  end

  # Records only a change to the stored flag. Clears the source after every save, so a source
  # named for a save that left the flag alone can't be recorded against a later change.
  def record_global_admin_change
    return unless saved_change_to_global_admin? && @global_admin_stored != global_admin

    GlobalAdminChange.create!(user_id: id, global_admin:, source: global_admin_source)
  ensure
    @global_admin_stored = nil
    self.global_admin_source = nil
  end
end
