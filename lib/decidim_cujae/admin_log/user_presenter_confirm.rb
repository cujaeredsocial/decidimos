# frozen_string_literal: true

module DecidimCujae
  module AdminLog
    # Gives the "confirm" admin log entries (logged by
    # Decidim::Admin::UserConfirmationsController) a proper sentence instead of
    # Decidim's generic "unknown action" one.
    # Prepended to Decidim::AdminLog::UserPresenter in
    # config/initializers/user_confirmations.rb.
    module UserPresenterConfirm
      private

      def action_string
        return "decidim.admin_log.user.confirm" if action.to_s == "confirm"

        super
      end
    end
  end
end
