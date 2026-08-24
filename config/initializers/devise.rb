# frozen_string_literal: true

Devise.setup do |config|
  # Tiempo de expiracion de tokens de invitacion (2 semanas)
  config.invite_for = 2.weeks

  # Tiempo de expiracion de tokens de verificacion de usuario
  config.confirm_within = 3.days
end
