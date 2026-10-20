# frozen_string_literal: true

require "test_helper"

class Tenant::FeedbackExchangesControllerTest < ActionDispatch::IntegrationTest
  PEER = "https://chip.example.com/api/feedback-exchange"
  OUTBOUND = "outbound-secret-outbound-secret-xx"
  INBOUND = "inbound-secret-inbound-secret-inbound"

  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
    end
  end

  def configure_tenant
    @tenant.update!(feedback_exchange_config: FeedbackExchangeConfig.new(peer_name: "chip", base_url: PEER, enabled: true))
    @tenant.update_feedback_exchange!(outbound_secret: OUTBOUND, inbound_secret: INBOUND)
  end

  def fake_client(health: nil, error: nil)
    client = Object.new
    client.define_singleton_method(:health) { error ? raise(error) : health }
    client
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    context "GET /integrations" do
      should "list the feedback exchange card as not configured" do
        get tenant_integrations_path

        assert_response :success
        assert_select "a[href='#{tenant_integration_path('feedback-exchange')}']", text: /Feedback exchange/
        assert_includes response.body, "Not configured"
      end

      should "show an active card once configured" do
        configure_tenant
        get tenant_integrations_path

        assert_includes response.body, "Feedback shared with chip"
        assert_includes response.body, "Active"
      end

      should "flag missing secrets" do
        @tenant.update!(feedback_exchange_config: FeedbackExchangeConfig.new(peer_name: "chip", base_url: PEER))
        get tenant_integrations_path

        assert_includes response.body, "Missing secrets"
      end
    end

    context "GET /integrations/feedback-exchange" do
      should "render the page with the form" do
        get tenant_integration_path("feedback-exchange")

        assert_response :success
        assert_select "h1", text: "Feedback exchange"
        assert_select "form[action='#{tenant_feedback_exchange_path}'] input[name='feedback_exchange[base_url]']"
        assert_select "input[type=password][name='feedback_exchange[outbound_secret]']"
        assert_select "#feedback-exchange-counts"
      end

      should "never echo a stored secret" do
        configure_tenant
        get tenant_integration_path("feedback-exchange")

        assert_response :success
        assert_not_includes response.body, OUTBOUND
        assert_not_includes response.body, INBOUND
        assert_select "input[type=password][name='feedback_exchange[outbound_secret]'][value='']"
        assert_includes response.body, "Stored"
      end
    end

    context "PATCH /integrations/feedback-exchange" do
      should "save the settings and the secrets" do
        patch tenant_feedback_exchange_path, params: { feedback_exchange: {
          peer_name: "chip", base_url: PEER, enabled: "1", outbound_secret: OUTBOUND, inbound_secret: INBOUND
        } }

        assert_redirected_to tenant_integration_path("feedback-exchange")
        config = @tenant.reload.feedback_exchange_config
        assert_equal "chip", config.peer_name
        assert_equal PEER, config.base_url
        assert config.enabled?
        assert_equal OUTBOUND, @tenant.feedback_exchange_secrets.outbound_secret
        assert_equal INBOUND, @tenant.feedback_exchange_secrets.inbound_secret
      end

      should "keep stored secrets when the fields are left blank" do
        configure_tenant

        patch tenant_feedback_exchange_path, params: { feedback_exchange: {
          peer_name: "chip", base_url: PEER, enabled: "0", outbound_secret: "", inbound_secret: ""
        } }

        assert_redirected_to tenant_integration_path("feedback-exchange")
        assert_not @tenant.reload.feedback_exchange_config.enabled?
        assert_equal OUTBOUND, @tenant.feedback_exchange_secrets.outbound_secret
        assert_equal INBOUND, @tenant.feedback_exchange_secrets.inbound_secret
      end

      should "keep the previous inbound secret when it is replaced" do
        configure_tenant

        patch tenant_feedback_exchange_path, params: { feedback_exchange: {
          peer_name: "chip", base_url: PEER, enabled: "1", inbound_secret: "a-brand-new-inbound-secret"
        } }

        assert_equal INBOUND, @tenant.reload.feedback_exchange_secrets.previous_inbound_secret
      end

      should "re-render with the errors and without the secrets when invalid" do
        patch tenant_feedback_exchange_path, params: { feedback_exchange: {
          peer_name: "Chip!", base_url: "http://chip.example.com", enabled: "1", outbound_secret: OUTBOUND
        } }

        assert_response :unprocessable_content
        assert_select "[role=alert]", text: /could not be saved/
        assert_includes response.body, "must start with https://"
        assert_includes response.body, "Peer name must be a slug"
        assert_not_includes response.body, "is invalid"
        assert_includes response.body, "Not configured" # the badge shows what is saved, not what was typed
        assert_not_includes response.body, OUTBOUND
        assert_includes response.body, "Not set"
        assert_equal "Chip!", css_select("input[name='feedback_exchange[peer_name]']").first["value"]
        assert_nil @tenant.reload.feedback_exchange_config.base_url
      end
    end

    context "POST /integrations/feedback-exchange/test_connection" do
      setup { configure_tenant }

      should "report a green connection" do
        FeedbackExchange::Client.stub(:for, fake_client(health: { "ok" => true, "peer" => "chip" })) do
          post test_connection_tenant_feedback_exchange_path
        end

        assert_redirected_to tenant_integration_path("feedback-exchange")
        assert_match(/Connected to chip/, flash[:notice])
      end

      should "work before the exchange is enabled" do
        @tenant.update!(feedback_exchange_config: @tenant.feedback_exchange_config.tap { |c| c.enabled = false })

        FeedbackExchange::Client.stub(:for, fake_client(health: { "ok" => true, "peer" => "chip" })) do
          post test_connection_tenant_feedback_exchange_path
        end

        assert_match(/Connected to chip/, flash[:notice])
      end

      should "say the signature was rejected" do
        FeedbackExchange::Client.stub(:for, fake_client(error: FeedbackExchange::Errors::AuthenticationError)) do
          post test_connection_tenant_feedback_exchange_path
        end

        assert_match(/rejected our signature/, flash[:alert])
      end

      should "name the status of a failing peer without echoing its body" do
        error = FeedbackExchange::Errors::ApiError.new(status: 503, body: "internal stack trace")
        FeedbackExchange::Client.stub(:for, fake_client(error: error)) do
          post test_connection_tenant_feedback_exchange_path
        end

        assert_match(/status 503/, flash[:alert])
        assert_not_includes flash[:alert], "stack trace"
      end

      should "say an unreachable peer could not be reached" do
        error = FeedbackExchange::Errors::ApiError.new(status: nil)
        FeedbackExchange::Client.stub(:for, fake_client(error: error)) do
          post test_connection_tenant_feedback_exchange_path
        end

        assert_match(/Could not reach/, flash[:alert])
      end

      should "say so when rate limited" do
        FeedbackExchange::Client.stub(:for, fake_client(error: FeedbackExchange::Errors::RateLimitError.new(retry_after: 30))) do
          post test_connection_tenant_feedback_exchange_path
        end

        assert_match(/rate limiting/, flash[:alert])
      end

      should "refuse a peer that does not say ok" do
        FeedbackExchange::Client.stub(:for, fake_client(health: { "ok" => false })) do
          post test_connection_tenant_feedback_exchange_path
        end

        assert_match(/not with/, flash[:alert])
      end

      should "ask for the settings first when none are saved" do
        @tenant.update_columns(feedback_exchange_credentials: nil)

        post test_connection_tenant_feedback_exchange_path

        assert_match(/Save the peer's address/, flash[:alert])
      end
    end
  end

  context "a rejected save with a login in the address" do
    should "name the field and keep the status on what is saved" do
      sign_in @admin_user
      patch tenant_feedback_exchange_path, params: { feedback_exchange: {
        peer_name: "chip", base_url: "https://u:p@chip.example.com/x", enabled: "1", outbound_secret: OUTBOUND, inbound_secret: INBOUND
      } }

      assert_response :unprocessable_content
      assert_includes response.body, "Peer address must be a plain address"
      assert_select "dd", text: "Stored", count: 0
      assert_select "dd", text: "Not set", count: 2
    end
  end

  context "as a non-admin member" do
    setup { sign_in @member_user }

    should "be redirected from the page" do
      get tenant_integration_path("feedback-exchange")

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end

    should "be refused a settings save, and change nothing" do
      patch tenant_feedback_exchange_path, params: { feedback_exchange: {
        peer_name: "chip", base_url: PEER, enabled: "1", outbound_secret: OUTBOUND, inbound_secret: INBOUND
      } }

      assert_redirected_to root_path
      assert_nil @tenant.reload.feedback_exchange_config.base_url
      assert_not @tenant.feedback_exchange_secrets.complete?
    end

    should "be refused a connection test" do
      FeedbackExchange::Client.stub(:for, ->(*) { flunk "the peer must not be called" }) do
        post test_connection_tenant_feedback_exchange_path
      end

      assert_redirected_to root_path
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
