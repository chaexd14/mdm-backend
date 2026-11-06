threads_count = Integer(ENV.fetch("RAILS_MAX_THREADS", 16))
threads threads_count, threads_count
port ENV.fetch("PORT", 3001)
plugin :tmp_restart
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
