# frozen_string_literal: true

module OmniAuth
  module Strategies
    class Xetid < OmniAuth::Strategies::OAuth2
      option :name, "xetid"

      option :client_options, {
        site: "https://identity.enzona.net",
        authorize_url: "/oauth2/authorize",
        token_url: "/oauth2/token",
        ssl: {
          verify: ENV.fetch("ENZONA_SSL_VERIFY", "false") == "true"
        }
      }

      option :authorize_options, [:scope]
      option :scope, "openid web-enzona"

      uid { raw_info["sub"] || raw_info["id"] }

      info do
        {
          email: raw_info["email"].presence,
          name: full_name.presence || raw_info["sub"].presence,
          nickname: raw_info["sub"].presence || raw_info["preferred_username"].presence,
          image: raw_info["picture"].presence
        }
      end

      extra do
        {
          raw_info: raw_info,
          identification: raw_info["identification"],
          person_verified: raw_info["person_verified"],
          phone_number: raw_info["phone_number"],
          zone: raw_info["zone"]
        }
      end

      def full_name
        [raw_info["given_name"], raw_info["family_name"]].compact.join(" ").presence
      end

      def raw_info
        @raw_info ||= access_token.get("/oauth2/userinfo").parsed
      end

      def callback_url
        full_host + script_name + callback_path
      end
    end
  end
end

# Replicar el mismo helper setup_provider_proc de decidim-core
def setup_provider_proc(provider, config_mapping = {})
  lambda do |env|
    request = Rack::Request.new(env)
    organization = Decidim::Organization.find_by(host: request.host)
    provider_config = organization.enabled_omniauth_providers[provider]

    config_mapping.each do |option_key, config_key|
      env["omniauth.strategy"].options[option_key] = provider_config[config_key]
    end
  end
end

# Agregar Xetid a la config de Decidim (aparece en el panel admin)
Decidim.configure do |config|
  config.omniauth_providers[:xetid] = {
    enabled: false,
    client_id: nil,
    client_secret: nil,
    icon_path: "media/images/enzona.svg"
  }
end

# Registrar middleware OAuth con setup_provider_proc (mismo patron que decidim-core)
Rails.application.config.middleware.use OmniAuth::Builder do
  if Decidim.omniauth_providers[:xetid]
    provider :xetid,
      setup: setup_provider_proc(:xetid, client_id: :client_id, client_secret: :client_secret)
  end
end
