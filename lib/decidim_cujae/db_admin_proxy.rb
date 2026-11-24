# frozen_string_literal: true

require "rack/proxy"

module DecidimCujae
  # Reverse proxy that serves the pgweb UI (https://github.com/sosedoff/pgweb)
  # ENV:
  #   DB_ADMIN_URL       backend URL (default: http://pgweb:8081)
  #   DB_ADMIN_USER      basic-auth user pgweb was started with (--auth-user)
  #   DB_ADMIN_PASSWORD  basic-auth password pgweb was started with (--auth-pass)
  class DbAdminProxy < Rack::Proxy
    def initialize(app = nil, opts = {})
      backend = ENV.fetch("DB_ADMIN_URL", "http://pgweb:8081")
      super(app, opts.merge(
        backend:,
        streaming: false,
        read_timeout: 300,
        username: ENV["DB_ADMIN_USER"].presence,
        password: ENV["DB_ADMIN_PASSWORD"].presence
      ))
    end

    def rewrite_env(env)
      env["HTTP_HOST"] = "#{@backend.host}:#{@backend.port}"
      # Don't leak the Decidim session cookie or a browser-sent Authorization
      # header to the backend.
      env.delete("HTTP_COOKIE")
      env.delete("HTTP_AUTHORIZATION")
      env
    end

    def rewrite_response(triplet)
      status, headers, body = triplet
      headers.delete("Set-Cookie")
      [status, headers, body]
    end
  end
end
