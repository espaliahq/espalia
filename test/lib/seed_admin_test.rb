# frozen_string_literal: true

require "test_helper"

class SeedAdminTest < ActiveSupport::TestCase
  DEV = ActiveSupport::StringInquirer.new("development")
  PROD = ActiveSupport::StringInquirer.new("production")

  def with_env(vars)
    old = vars.keys.index_with { |key| ENV[key] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def bootstrap(env:, **vars)
    output = StringIO.new
    user = with_env({ "SEED_ADMIN_EMAIL" => nil, "SEED_ADMIN_PASSWORD" => nil }.merge(vars)) do
      SeedAdmin.bootstrap!(env: env, output: output)
    end
    [ user, output.string ]
  end

  should "create the fixed dev admin outside production and say how to sign in" do
    user, output = bootstrap(env: DEV)

    assert user.global_admin?
    assert_equal SeedAdmin::DEV_EMAIL, user.email
    assert_includes output, "Sign in with admin@example.com / password123"
  end

  should "create from SEED_ADMIN_* in production without printing the password" do
    user, output = bootstrap(env: PROD, "SEED_ADMIN_EMAIL" => "ops@example.org", "SEED_ADMIN_PASSWORD" => "s3eded-secret")

    assert user.global_admin?
    assert_equal "ops@example.org", user.email
    assert_includes output, "the SEED_ADMIN_PASSWORD you set"
    assert_not_includes output, "s3eded-secret"
  end

  should "be a no-op once the admin exists" do
    existing, = bootstrap(env: DEV)

    user, output = bootstrap(env: DEV)

    assert_equal existing.id, user.id
    assert_includes output, "already exists"
  end

  should "hand back any existing global admin in production with nothing set" do
    existing = create(:user, global_admin: true)

    user, output = bootstrap(env: PROD)

    assert_equal existing.id, user.id
    assert_includes output, "already exists"
  end

  should "refuse a first production deploy that sets nothing" do
    error = assert_raises(ArgumentError) { bootstrap(env: PROD) }

    assert_match(/SEED_ADMIN_EMAIL/, error.message)
  end

  should "refuse an email without a password" do
    assert_raises(ArgumentError) { bootstrap(env: PROD, "SEED_ADMIN_EMAIL" => "ops@example.org") }
  end
end
