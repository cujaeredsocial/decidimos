# frozen_string_literal: true

module DecidimCujae
  # "Verified account" = the participant is a real, identified person.
  #
  # One Decidim authorization (name "verified_account") that can be granted
  # in two ways, recorded in its metadata["method"]:
  #   - "enzona": the participant signed in to EnZona from
  #     My account > Authorizations (unique_id = EnZona subject id, so one
  #     EnZona identity can verify a single account per organization).
  #   - "manual": an admin verified them in Admin > Participants >
  #     Account verification.
  #
  # Admins require it per action in each component's Permissions.
  #
  # NOT autoloaded (ignored in config/application.rb): the workflow is
  # registered from config/initializers/verified_account.rb, and Rails 7.2
  # does not autoload reloadable code during initialization. The controller
  # and the command under this namespace (app/) are autoloaded as usual.
  module VerifiedAccount
    WORKFLOW = "verified_account"
    METHODS = %w(enzona manual).freeze
    # Shakapacker asset app/packs/images/enzona.png (128x123, ~5 KB). Render
    # it with image_pack_tag. It replaced enzona.svg, an 890 KB PNG wrapped in
    # SVG that external_icon inlined whole into every page.
    ENZONA_ICON = "media/images/enzona.png"

    # Participant side of the workflow. decidim-verifications mounts it at
    # /verified_account (signed-in users only).
    # Mirrors Decidim::Verifications::PostalLetter::Engine.
    class Engine < ::Rails::Engine
      isolate_namespace DecidimCujae::VerifiedAccount

      # Without this the engine root would resolve to the app root and load
      # the app's initializers and paths a second time.
      config.root = __dir__

      paths["db/migrate"] = nil
      paths["lib/tasks"] = nil

      # This engine is defined while the app initializers run, after Rails
      # collected the route sets it draws, so the initializer also registers
      # these routes in Rails.application.routes_reloader (see
      # config/initializers/verified_account.rb).
      routes do
        resource :authorization, only: [:new, :edit] do
          get :enzona
          get :callback
        end

        root to: "authorizations#new"
      end
    end
  end
end
