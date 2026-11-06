Rails.application.routes.draw do
  get "/api/auth", to: "enrollments#auth"
  get '/api/app-releases', to: 'app_releases#index'
  post '/api/app-releases', to: 'app_releases#create'
  patch '/api/app-releases/:id', to: 'app_releases#change'
  post '/api/app-releases/:id/assign', to: 'app_releases#assign'
  post '/api/device-updates/:id/control', to: 'app_releases#control'
  get '/api/devices/:device_id/updates/current', to: 'device_updates#current'
  post '/api/devices/:device_id/updates/:id/report', to: 'device_updates#report'
  post '/api/devices/:device_id/updates/:id/permit', to: 'device_updates#permit'
  get '/api/devices/:device_id/updates/:id/apk', to: 'device_updates#artifact'
  get "up", to: "rails/health#show"
  # Preserve the API routes migrated from the web dashboard, including legacy aliases.
  %w[/api/devices /api/kiosks /api/v1/kiosks].each do |prefix|
    scope prefix, format: false do
      get "/", to: "devices#index"
      post "/enroll", to: "enrollments#redeem"
      post "/:device_id/enrollment", to: "enrollments#create"
      post "/:device_id/commands/:command_id/cancel", to: "commands#cancel"
      post "/register", to: "devices#register"
      post "/heartbeat", to: "devices#heartbeat"
      get "/commands/summary", to: "commands#summary"
      get "/commands", to: "commands#index"
      get "/events", to: "events#index"
      get "/:device_id/config", to: "devices#configuration"
      patch "/:device_id/maintenance", to: "devices#maintenance"
      patch "/:device_id/url", to: "devices#url"
      get "/:device_id/commands", to: "commands#pending"
      post "/:device_id/commands", to: "commands#create"
      post "/:device_id/commands/:command_id/ack", to: "commands#ack"
      get "/:device_id", to: "devices#show"
      patch "/:device_id", to: "devices#update"
      delete "/:device_id", to: "devices#destroy"
    end
  end
  get "/api/kiosks/v1/:device_id/commands", to: "commands#pending"
  match "/api/*path", to: "application#options", via: :options
end
