# frozen_string_literal: true

# Manual account confirmation (no mail server yet): makes a sign-up a
# registered user. Identity verification is a separate step, see
# config/initializers/verified_account.rb.
# See app/controllers/decidim/admin/user_confirmations_controller.rb.

# Admin route: /admin/user_confirmations. Same pattern Decidim modules use to
# extend the admin engine (e.g. decidim-demographics admin_engine.rb).
Decidim::Admin::Engine.routes do
  resources :user_confirmations, only: [:index, :update]
end

# Entry in Admin > Participants secondary menu.
Decidim.menu :admin_user_menu do |menu|
  menu.add_item :user_confirmations,
                I18n.t("decidim.admin.menu.user_confirmations"),
                decidim_admin.user_confirmations_path,
                icon_name: "user-follow-line",
                active: is_active_link?(decidim_admin.user_confirmations_path),
                if: allowed_to?(:read, :officialization)
end

Rails.application.config.to_prepare do
  Decidim::AdminLog::UserPresenter.prepend(DecidimCujae::AdminLog::UserPresenterActions)
end
