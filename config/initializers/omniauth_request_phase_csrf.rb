# frozen_string_literal: true

# OmniAuth 2 (omniauth-rails_csrf_protection) valida el token CSRF en la fase
# "request" (/users/auth/:provider). El botón de Decidim envía el token que se
# generó cuando se renderizó la página. Si la pestaña queda abierta y se
# inicia/cierra sesión en otra, o se vuelve con el botón "atrás", ese token
# deja de coincidir con la sesión actual y Rails responde 422
# InvalidAuthenticityToken antes de llegar al proveedor.
#
# La fase request solo redirige a Enzona y no modifica estado; el callback
# valida el parametro "state", por lo que desactivar esta verificacion
# adicional no habilita un login CSRF. El resto de formularios siguen
# protegidos por Rails.
OmniAuth.config.request_validation_phase = ->(_env) { true }
