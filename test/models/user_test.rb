# frozen_string_literal: true

require "test_helper"

class UserTest < ActiveSupport::TestCase
  subject { build(:user) }

  context "associations" do
    should have_many(:tenant_users).dependent(:destroy)
    should have_many(:tenants).through(:tenant_users)
  end

  context "notification preferences" do
    should "default to an empty hash" do
      assert_equal({}, build(:user).notification_preferences)
    end

    should "resolve #notifies_via? from registry defaults when unset" do
      user = build(:user)
      assert user.notifies_via?(:evidence_requested, :slack)
      assert_not user.notifies_via?(:evidence_request_responded, :slack)
    end

    should "persist and honour overrides via #update_notification_preference" do
      user = create(:user)
      assert user.update_notification_preference(:evidence_requested, slack: false, in_app: true)

      user.reload
      assert_not user.notifies_via?(:evidence_requested, :slack)
      assert user.notifies_via?(:evidence_requested, :in_app)
    end

    should "ignore unknown channels and reject unknown types" do
      user = create(:user)
      assert user.update_notification_preference(:evidence_requested, sms: true, slack: false)
      assert_not user.notification_preferences["evidence_requested"].key?("sms")

      assert_not user.update_notification_preference(:nonexistent_type, slack: true)
    end

    should "preserve an existing channel override when another channel is updated" do
      user = create(:user)
      user.update_notification_preference(:evidence_requested, email: false)
      user.update_notification_preference(:evidence_requested, slack: false) # settings UI omits email

      user.reload
      assert_not user.notifies_via?(:evidence_requested, :email), "email override must survive a slack-only update"
      assert_not user.notifies_via?(:evidence_requested, :slack)
    end
  end

  context "validations" do
    should validate_presence_of(:email)
    should validate_uniqueness_of(:email).case_insensitive
  end

  context "color scheme" do
    should "default to auto" do
      assert_equal "auto", build(:user).color_scheme
    end

    should "accept light and dark and reject anything else" do
      user = build(:user)
      %w[auto light dark].each do |scheme|
        user.color_scheme = scheme
        assert user.valid?, "#{scheme} should be valid"
      end

      user.color_scheme = "sepia"
      assert_not user.valid?
      assert user.errors.added?(:color_scheme, :inclusion, value: "sepia")
    end

    should "give data_scheme only for an explicit choice" do
      assert_nil build(:user, color_scheme: :auto).data_scheme
      assert_equal "light", build(:user, color_scheme: :light).data_scheme
      assert_equal "dark", build(:user, color_scheme: :dark).data_scheme
    end
  end

  context "global_admin?" do
    should "return false by default" do
      assert_not subject.global_admin?
    end

    should "return true when global_admin is set" do
      user = build(:user, global_admin: true)
      assert user.global_admin?
    end
  end

  def build_auth(email:, uid: "google-uid-1", verified: true)
    OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: uid,
      info: { "email" => email, "email_verified" => verified, "name" => "Test User" },
      extra: { raw_info: { "email_verified" => verified } }
    )
  end

  context ".from_google_omniauth" do
    should "refuse when the Google email is not verified" do
      user, reason = User.from_google_omniauth(build_auth(email: "x@example.com", verified: false))
      assert_nil user
      assert_equal :email_unverified, reason
    end

    should "refuse with :invalid_payload when the auth hash is missing fields" do
      _, reason = User.from_google_omniauth(OmniAuth::AuthHash.new(provider: "google_oauth2"))
      assert_equal :invalid_payload, reason
    end

    should "return the existing User and backfill provider/uid when matched by email" do
      user = create(:user, email: "alice@example.com")
      assert_nil user.provider

      result, reason = User.from_google_omniauth(build_auth(email: "Alice@example.com", uid: "uid-42"))

      assert_nil reason
      assert_equal user.id, result.id
      result.reload
      assert_equal "google_oauth2", result.provider
      assert_equal "uid-42", result.uid
    end

    should "return the existing User unchanged when matched by provider+uid" do
      user = create(:user, email: "bob@example.com", provider: "google_oauth2", uid: "uid-7")
      result, reason = User.from_google_omniauth(build_auth(email: "bob+changed@example.com", uid: "uid-7"))

      assert_nil reason
      assert_equal user.id, result.id
    end

    should "auto-create User and TenantUser when only a Person matches" do
      tenant = create(:tenant)
      person = ActsAsTenant.with_tenant(tenant) do
        create(:person, tenant: tenant, email: "carol@example.com")
      end

      assert_difference -> { User.count } => 1, -> { TenantUser.count } => 1 do
        result, reason = User.from_google_omniauth(build_auth(email: "Carol@example.com", uid: "uid-9"))
        assert_nil reason
        assert_equal "carol@example.com", result.email
        assert_equal "google_oauth2", result.provider
      end

      tenant_user = TenantUser.where(tenant: tenant).order(:created_at).last
      assert_equal person.id, tenant_user.person_id
      assert_equal "member", tenant_user.role
    end

    should "refuse with :no_matching_account when no User and no Person matches" do
      user, reason = User.from_google_omniauth(build_auth(email: "stranger@example.com", uid: "uid-x"))
      assert_nil user
      assert_equal :no_matching_account, reason
    end

    should "recover by re-linking when a concurrent sign-in already created the User" do
      tenant = create(:tenant)
      ActsAsTenant.with_tenant(tenant) do
        create(:person, tenant: tenant, email: "dana@example.com")
      end

      # Simulate the race: provision_from_person! raises RecordNotUnique
      # because another request created the User mid-flight. The winning
      # User is created INSIDE the stub so the first lookups in
      # from_google_omniauth miss and the rescue branch is exercised.
      existing = nil
      called = false
      result = reason = nil
      User.stub(:provision_from_person!, lambda { |*|
        called = true
        existing = create(:user, email: "dana@example.com", provider: "google_oauth2", uid: "uid-race")
        raise ActiveRecord::RecordNotUnique
      }) do
        result, reason = User.from_google_omniauth(build_auth(email: "dana@example.com", uid: "uid-race"))
      end

      assert called, "expected provision_from_person! to be invoked"
      assert_nil reason
      assert_equal existing.id, result.id
    end
  end
end
