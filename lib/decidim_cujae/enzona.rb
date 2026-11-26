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
  #   ENZONA_CALLBACK_PATH                     redirect URI path sent to EnZona, one of
  #                                            CALLBACK_PATHS (default LEGACY_CALLBACK_PATH)
  #
  # Both callback paths work: the legacy one (the URI registered in EnZona
  # when it was a sign-in provider) redirects to the new one, see
  # config/routes.rb. ENZONA_CALLBACK_PATH only picks which one is sent as
  # redirect_uri, which must match a URI registered in EnZona.
  module Enzona
    SCOPE = "openid web-enzona"
    LEGACY_CALLBACK_PATH = "/users/auth/xetid/callback"
    CALLBACK_PATH = "/verified_account/authorization/callback"
    CALLBACK_PATHS = [LEGACY_CALLBACK_PATH, CALLBACK_PATH].freeze

    module_function

    def configured?
      client_id.present? && client_secret.present?
    end

    # Full redirect URI to send to EnZona for a request on base_url
    # (scheme + host + port).
    def redirect_uri(base_url)
      path = ENV.fetch("ENZONA_CALLBACK_PATH", LEGACY_CALLBACK_PATH)
      path = LEGACY_CALLBACK_PATH unless CALLBACK_PATHS.include?(path)
      "#{base_url}#{path}"
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
