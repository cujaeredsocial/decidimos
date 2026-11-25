# frozen_string_literal: true

# "Verified account" workflow: a participant is a real person once they sign
# in to EnZona from My account > Authorizations, or once an admin verifies
# them manually. See lib/decidim_cujae/verified_account.rb.
#
# Enable it per organization in /system (Available authorizations), then
# require it per action in each component's Permissions.
# Mirrors decidim-verifications/lib/decidim/verifications/postal_letter/workflow.rb.
require Rails.root.join("lib/decidim_cujae/verified_account").to_s

# Engines loaded with Bundler get their routes drawn by Rails; this one is
# defined too late for that, so hand its route set to the app's reloader
# (drawn and finalized with the others, also on dev reloads).
Rails.application.routes_reloader.route_sets << DecidimCujae::VerifiedAccount::Engine.routes

Decidim::Verifications.register_workflow(:verified_account) do |workflow|
  workflow.engine = DecidimCujae::VerifiedAccount::Engine
  # Image path, not a Remixicon name: shown in My account > Authorizations
  # by the overridden app/views/decidim/verifications/authorizations/_item.html.erb.
  workflow.icon = DecidimCujae::VerifiedAccount::ENZONA_ICON
  # Renewing destroys the authorization, which would undo an admin's manual
  # verification. Admins revoke it from Account verification instead.
  workflow.renewable = false
end

# Admin route: /admin/user_verifications (manual verification).
# Same pattern as config/initializers/user_confirmations.rb.
Decidim::Admin::Engine.routes do
  resources :user_verifications, only: [:index, :update, :destroy]
end

Decidim.menu :admin_user_menu do |menu|
  menu.add_item :user_verifications,
                I18n.t("decidim.admin.menu.user_verifications"),
                decidim_admin.user_verifications_path,
                icon_name: "fingerprint-line",
                active: is_active_link?(decidim_admin.user_verifications_path),
                if: allowed_to?(:read, :officialization)
end
