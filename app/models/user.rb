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
  has_prefix_id :usr

  has_many :tenant_users, dependent: :destroy
  has_many :tenants, through: :tenant_users

  # Include default devise modules. :validatable is included because email
  # uniqueness is now global (no tenant scope on User).
  devise :database_authenticatable, :registerable,
    :recoverable, :rememberable, :validatable,
    :omniauthable, omniauth_providers: [ :google_oauth2 ]

  # @return [Boolean] whether this user has global admin privileges
  def global_admin?
    global_admin
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
