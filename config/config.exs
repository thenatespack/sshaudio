import Config

if config_env() == :test do
  config :sshaudio, ssh_port: 0
end
