Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins(*ENV.fetch("FRONTEND_ORIGINS", "http://localhost:3000,http://127.0.0.1:3000").split(",").map(&:strip))
    resource "/api/*", headers: :any, methods: %i[get post patch delete options], expose: ["Last-Event-ID"]
  end
end
