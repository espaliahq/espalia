# frozen_string_literal: true

require "test_helper"

class Tenant::AiModelsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  GATEWAY = "https://ai-gateway.vercel.sh/v1"
  KEY = "sk-gateway-secret-key-1234567890"

  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
    end
  end

  def configure_gateway(suggestions: true)
    @tenant.update_ai_model!(
      settings: { provider: "openai_compatible", base_url: GATEWAY, model: "anthropic/claude-opus-5-5", suggestions_enabled: suggestions },
      api_key: KEY
    )
  end

  def fake_adapter(reply: nil, error: nil, model: "anthropic/claude-opus-5-5")
    adapter = Object.new
    adapter.define_singleton_method(:model) { model }
    adapter.define_singleton_method(:ping) { error ? raise(error) : reply }
    adapter
  end

  def settings(overrides = {})
    { ai_model: { provider: "openai_compatible", base_url: GATEWAY, model: "anthropic/claude-opus-5-5",
                  effort: "low", suggestions_enabled: "1", api_key: KEY }.merge(overrides) }
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    context "GET /integrations" do
      should "list the AI model card as not configured" do
        get tenant_integrations_path

        assert_response :success
        assert_select "a[href='#{tenant_integration_path('ai-model')}']", text: /AI model/
        assert_includes response.body, "Not configured"
      end

      should "show the model and host once configured" do
        configure_gateway
        get tenant_integrations_path

        assert_includes response.body, "anthropic/claude-opus-5-5 · ai-gateway.vercel.sh"
        assert_includes response.body, "Active"
      end

      should "show a configured model with suggestions off as off" do
        configure_gateway(suggestions: false)
        get tenant_integrations_path

        assert_includes response.body, "Suggestions off"
      end
    end

    context "GET /integrations/ai-model" do
      should "render the page with the form" do
        get tenant_integration_path("ai-model")

        assert_response :success
        assert_select "h1", text: "AI model"
        assert_select "form[action='#{tenant_ai_model_path}']"
        assert_select "select[name='ai_model[provider]']"
        assert_select "input[name='ai_model[base_url]']"
        assert_select "input[name='ai_model[model]']"
        assert_select "input[type=password][name='ai_model[api_key]']"
        assert_select "input[type=checkbox][name='ai_model[suggestions_enabled]']"
        assert_select "input[name='ai_model[pseudonymise_names]']", count: 0
        assert_select "dt", text: "Names hidden", count: 0
        assert_select "option", text: "Vercel AI Gateway: Jev (TypeSafe AI)"
      end

      should "say self feedback goes to the model too" do
        get tenant_integration_path("ai-model")

        assert_includes response.body, "when it is recorded or edited, self feedback included"
        assert_not_includes response.body, "Self feedback never does"
      end

      should "never echo a stored key" do
        configure_gateway
        get tenant_integration_path("ai-model")

        assert_response :success
        assert_not_includes response.body, KEY
        assert_select "input[type=password][name='ai_model[api_key]'][value='']"
        assert_includes response.body, "Stored"
        assert_select "select#ai_model_preset option[selected]", text: "Vercel AI Gateway: a chat model"
      end

      should "report no key for a legacy tenant until one is saved through the card" do
        @tenant.update!(settings: { "evidence_suggestions_enabled" => true })
        get tenant_integration_path("ai-model")

        assert_response :success
        assert_not_includes response.body, "Leave blank to keep it"
        assert_select "input[type=password][name='ai_model[api_key]'][placeholder^='Paste']"
        assert_select "dl", text: /API key\s*Not set/, message: "there is no deployment key to fall back to"
      end

      should "start the form from the legacy switch for a tenant that has not been saved through the card" do
        @tenant.update!(settings: { "evidence_suggestions_enabled" => true, "evidence_suggestions_model" => "claude-haiku-5-5" })
        get tenant_integration_path("ai-model")

        assert_select "input[type=checkbox][name='ai_model[suggestions_enabled]'][checked]"
        assert_select "input[name='ai_model[model]'][value='claude-haiku-5-5']"
      end
    end

    context "PATCH /integrations/ai-model" do
      should "save the settings and the key" do
        patch tenant_ai_model_path, params: settings

        assert_redirected_to tenant_integration_path("ai-model")
        config = @tenant.reload.ai_config
        assert_equal "openai_compatible", config.provider
        assert_equal GATEWAY, config.base_url
        assert_equal "anthropic/claude-opus-5-5", config.model
        assert config.suggestions_enabled?
        assert_equal KEY, @tenant.ai_secrets.api_key
      end

      should "save Jev on the gateway, with the gateway preset selected and no effort on offer" do
        patch tenant_ai_model_path, params: settings(provider: "typesafe_jev", model: "typesafe-ai/jev")

        config = @tenant.reload.ai_config
        assert_equal [ "typesafe_jev", GATEWAY, "typesafe-ai/jev" ], [ config.provider, config.base_url, config.model ]

        get tenant_integration_path("ai-model")
        assert_select "select#ai_model_preset option[selected]", text: "Vercel AI Gateway: Jev (TypeSafe AI)"
        assert_select "select#ai_model_provider option[selected]", text: "Jev (TypeSafe AI)"
        assert_select "[data-ai-model-preset-target='effortRow'][hidden]"
      end

      should "show Jev off the gateway as the other Jev endpoint" do
        patch tenant_ai_model_path, params: settings(provider: "typesafe_jev", base_url: "https://jev.example.com/v1", model: "typesafe-ai/jev")

        get tenant_integration_path("ai-model")
        assert_select "select#ai_model_preset option[selected]", text: "Other Jev endpoint"
      end

      should "keep the stored key when the field is left blank, and turn suggestions off" do
        configure_gateway

        patch tenant_ai_model_path, params: settings(api_key: "", suggestions_enabled: "0")

        assert_redirected_to tenant_integration_path("ai-model")
        assert_not @tenant.reload.ai_config.suggestions_enabled?
        assert_equal KEY, @tenant.ai_secrets.api_key
      end

      should "save a form from before the name switch went, ignoring the switch" do
        patch tenant_ai_model_path, params: settings(pseudonymise_names: "0")

        assert_redirected_to tenant_integration_path("ai-model")
        assert_not_includes @tenant.reload.read_attribute_before_type_cast(:ai_config).to_s, "pseudonymise_names"
      end

      should "store a blank address and model as nothing, and trim what it keeps" do
        patch tenant_ai_model_path, params: settings(provider: "anthropic", base_url: "  ", model: "  claude-haiku-5-5 ")

        assert_nil @tenant.reload.ai_config.base_url
        assert_equal "claude-haiku-5-5", @tenant.ai_config.model
      end

      should "re-render with the errors and without the key when invalid" do
        patch tenant_ai_model_path, params: settings(base_url: "http://gw.example.com/v1", api_key: KEY)

        assert_response :unprocessable_content
        assert_includes response.body, "The settings could not be saved."
        assert_includes response.body, "must start with https://"
        assert_not_includes response.body, KEY
        assert_nil @tenant.reload.ai_secrets.api_key, "a rejected save stores nothing"
        assert_includes response.body, "Not set"
      end

      should "refuse a private network address" do
        patch tenant_ai_model_path, params: settings(base_url: "https://10.0.0.5/v1")

        assert_response :unprocessable_content
        assert_includes response.body, "must not be a private network address"
      end

      should "require an address and model for an OpenAI-compatible endpoint" do
        patch tenant_ai_model_path, params: settings(base_url: "", model: "")

        assert_response :unprocessable_content
        assert_includes response.body, "Address can&#39;t be blank"
        assert_includes response.body, "Model can&#39;t be blank"
      end

      should "refuse a stored key being pointed at another address without entering it again" do
        configure_gateway

        patch tenant_ai_model_path, params: settings(base_url: "https://other-gateway.example.com/v1", api_key: "")

        assert_response :unprocessable_content
        assert_includes response.body, "Enter the API key again."
        assert_equal GATEWAY, @tenant.reload.ai_config.base_url
        assert_equal KEY, @tenant.ai_secrets.api_key
        assert_select "input[name='ai_model[base_url]'][value='https://other-gateway.example.com/v1']"
      end

      should "report a bad address before the key rule, so both are fixed in one go" do
        configure_gateway

        patch tenant_ai_model_path, params: settings(base_url: "http://gateway.example.com/v1", api_key: "")

        assert_response :unprocessable_content
        assert_includes response.body, "must start with https://"
        assert_not_includes response.body, "Enter the API key again."
      end

      should "accept the move when the key is entered again" do
        configure_gateway

        patch tenant_ai_model_path, params: settings(base_url: "https://other-gateway.example.com/v1", api_key: "sk-new-key")

        assert_redirected_to tenant_integration_path("ai-model")
        assert_equal "sk-new-key", @tenant.reload.ai_secrets.api_key
      end

      should "refuse switching suggestions on with no key" do
        patch tenant_ai_model_path, params: settings(api_key: "")

        assert_response :unprocessable_content
        assert_includes response.body, "Add an API key to switch suggestions on."
        assert_not @tenant.reload.ai_config.suggestions_enabled?
      end

      should "say a legacy tenant's deployment key does not carry over" do
        @tenant.update!(settings: { "evidence_suggestions_enabled" => true })

        patch tenant_ai_model_path, params: settings(provider: "anthropic", base_url: "", model: "", api_key: "")

        assert_response :unprocessable_content
        assert_includes response.body, "using the deployment&#39;s key"
        assert @tenant.reload.legacy_evidence_suggestions_enabled?, "a refused save changes nothing"
      end

      should "ignore a key that is not a string instead of failing" do
        patch tenant_ai_model_path, params: { ai_model: settings[:ai_model].except(:api_key).merge(api_key: [ "x" ]) }

        assert_response :unprocessable_content
        assert_includes response.body, "Add an API key to switch suggestions on."
      end

      should "drop the legacy settings keys on save" do
        @tenant.update!(settings: { "evidence_suggestions_enabled" => true })

        patch tenant_ai_model_path, params: settings(suggestions_enabled: "0", api_key: "")

        assert_not @tenant.reload.legacy_evidence_suggestions_enabled?
        assert_not @tenant.evidence_suggestions_enabled?
      end
    end

    context "POST /integrations/ai-model/test_connection" do
      should "show the model's reply" do
        configure_gateway

        Ai::ModelClient.stub(:for, fake_adapter(reply: "ready")) do
          post test_connection_tenant_ai_model_path
        end

        assert_redirected_to tenant_integration_path("ai-model")
        assert_equal "Connected. anthropic/claude-opus-5-5 replied: “ready”", flash[:notice]
      end

      should "ping Jev with a boolean question and show its answer" do
        @tenant.update_ai_model!(settings: { provider: "typesafe_jev", base_url: GATEWAY, model: "typesafe-ai/jev" }, api_key: KEY)
        sent = nil
        stubs = Faraday::Adapter::Test::Stubs.new
        stubs.post("/v1/evaluate") do |env|
          sent = JSON.parse(env.body)
          [ 200, { "Content-Type" => "application/json" },
            { model: "typesafe-ai/jev", answers: { reachable: { type: "boolean", probability: 0.98 } } }.to_json ]
        end
        adapter = Ai::TypesafeJev::Adapter.new(api_key: KEY, base_url: GATEWAY, model: "typesafe-ai/jev",
                                               connection: Faraday.new(url: "#{GATEWAY}/") { |f| f.adapter :test, stubs })

        Ai::ModelClient.stub(:for, adapter) { post test_connection_tenant_ai_model_path }

        assert_equal "boolean", sent.dig("questions", "reachable", "type")
        assert_equal "Connected. typesafe-ai/jev replied: “yes, 98% sure this is a connection check”", flash[:notice]
      end

      should "name each failure without echoing the endpoint's body or the key" do
        configure_gateway
        {
          Ai::Errors::AuthenticationError.new("bad") => "The endpoint rejected the API key.",
          Ai::Errors::RateLimitError.new(retry_after: 3) => "The endpoint is rate limiting us. Try again in a minute.",
          Ai::Errors::ConfigurationError.new("The model endpoint's address points at a private network address, which is not allowed") =>
            "The model endpoint's address points at a private network address, which is not allowed",
          Ai::Errors::RefusalError.new("no") => "The model declined the test request. The key and address work.",
          Ai::Errors::ApiError.new(status: 404, body: "model sk-leak not found") => "The endpoint answered with status 404. Check the address and the model id.",
          Ai::Errors::ApiError.new(status: 502, body: "<html>sk-leak</html>") => "The endpoint answered with status 502.",
          Ai::Errors::ApiError.new(status: nil, message: "Could not reach the model endpoint: ConnectionFailed") => "Could not reach the model endpoint: ConnectionFailed"
        }.each do |failure, message|
          Ai::ModelClient.stub(:for, fake_adapter(error: failure)) { post test_connection_tenant_ai_model_path }

          assert_equal message, flash[:alert]
          assert_not_includes flash[:alert], "sk-leak"
        end
      end

      should "say so when the model said nothing" do
        configure_gateway
        Ai::ModelClient.stub(:for, fake_adapter(reply: "")) { post test_connection_tenant_ai_model_path }

        assert_equal "The endpoint answered, but the model said nothing.", flash[:alert]
      end

      should "ask for a complete model and a key first, without calling out" do
        Ai::ModelClient.stub(:for, ->(*) { flunk "no call without a configured model" }) do
          post test_connection_tenant_ai_model_path
        end

        assert_equal "Save a complete model and an API key first.", flash[:alert]
      end
    end
  end

  context "as a non-admin member" do
    setup { sign_in @member_user }

    should "be redirected away from the page" do
      get tenant_integration_path("ai-model")

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end

    should "not be able to save, and nothing is stored" do
      patch tenant_ai_model_path, params: settings

      assert_redirected_to root_path
      assert_nil @tenant.reload.ai_secrets.api_key
      assert_not @tenant.ai_config.suggestions_enabled?
    end

    should "not be able to test the connection" do
      configure_gateway
      Ai::ModelClient.stub(:for, ->(*) { flunk "a member must not reach the model" }) do
        post test_connection_tenant_ai_model_path
      end

      assert_redirected_to root_path
    end
  end

  context "when signed out" do
    should "be sent to sign in" do
      patch tenant_ai_model_path, params: settings

      assert_response :redirect
      assert_nil @tenant.reload.ai_secrets.api_key
    end
  end
end
