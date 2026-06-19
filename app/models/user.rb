# frozen_string_literal: true

# Authentication identity for a GrowthOS user.
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

  # Include default devise modules. :validatable is included because email
  # uniqueness is now global (no tenant scope on User).
  devise :database_authenticatable, :registerable,
    :recoverable, :rememberable, :validatable,
    :omniauthable, omniauth_providers: [ :google_oauth2 ]

  # @return [Boolean] whether this user has global admin privileges
  def global_admin?
    global_admin
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

    merged = notification_preferences.merge(type_key.to_s => overrides)
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
        TenantUser.create!(tenant: person.tenant, user: user, person: person, role: :member)
      end
      user
    end
  end

  private_class_method :google_email_verified?, :provision_from_person!
end
