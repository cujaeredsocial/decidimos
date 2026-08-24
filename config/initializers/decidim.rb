# frozen_string_literal: true

Decidim.configure do |config|
  # Tiempo de expiracion de sesion por inactividad (recomendado 15 min)
  config.expire_session_after = 15.minutes

  # Vida maxima del access token OAuth2 (7200s = 2 horas)
  config.oauth_access_token_expires_in = 2.hours
end
