# frozen_string_literal: true

module DecidimCujae
  # OAuth2 client for EnZona (XETID identity server).
  #
  # EnZona is no longer a sign-in method: it is only used to verify the
  # identity of participants who are already signed in (see the
  # :verified_account workflow in config/initializers/verified_account.rb).
  #
  # Credentials come from ENV (they used to live in the org's omniauth
  # settings in /system):
  #   ENZONA_CLIENT_ID, ENZONA_CLIENT_SECRET   required
  #   ENZONA_SITE                              default https://identity.enzona.net
  #   ENZONA_SSL_VERIFY                        "true" to verify the TLS cert (default "false")
  module Enzona
    SCOPE = "openid web-enzona"

    module_function

    def configured?
      client_id.present? && client_secret.present?
    end

    def client
      OAuth2::Client.new(
        client_id,
        client_secret,
        site: ENV.fetch("ENZONA_SITE", "https://identity.enzona.net"),
        authorize_url: "/oauth2/authorize",
        token_url: "/oauth2/token",
        ssl: { verify: ENV.fetch("ENZONA_SSL_VERIFY", "false") == "true" }
      )
    end

    def authorize_url(redirect_uri:, state:)
      client.auth_code.authorize_url(redirect_uri:, scope: SCOPE, state:)
    end

    # Exchanges the authorization code and returns the EnZona subject id
    # (stable per person), or nil when the userinfo response has none.
    def fetch_uid(code, redirect_uri:)
      token = client.auth_code.get_token(code, redirect_uri:)
      info = token.get("/oauth2/userinfo").parsed || {}
      (info["sub"] || info["id"]).presence&.to_s
    end

    def client_id
      ENV.fetch("ENZONA_CLIENT_ID", nil)
    end

    def client_secret
      ENV.fetch("ENZONA_CLIENT_SECRET", nil)
    end
  end
end
