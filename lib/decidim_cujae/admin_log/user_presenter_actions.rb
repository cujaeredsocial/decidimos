# frozen_string_literal: true

module DecidimCujae
  module AdminLog
    # Gives the custom admin log entries on users a proper sentence instead of
    # Decidim's generic "unknown action" one:
    #   confirm  - Decidim::Admin::UserConfirmationsController
    #   verify   - DecidimCujae::VerifiedAccount::GrantVerification (manual)
    #   unverify - Decidim::Admin::UserVerificationsController#destroy
    # Prepended to Decidim::AdminLog::UserPresenter in
    # config/initializers/user_confirmations.rb.
    module UserPresenterActions
      ACTIONS = %w(confirm verify unverify).freeze

      private

      def action_string
        return "decidim.admin_log.user.#{action}" if ACTIONS.include?(action.to_s)

        super
      end
    end
  end
end
