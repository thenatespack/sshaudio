defmodule SSHAudio.SSH.HostKeys do
  @moduledoc """
  Loads the SSH daemon's host key from disk, generating and writing one
  on first boot. Keeping the key on disk (instead of only in memory)
  means the fingerprint stays stable across restarts, so clients don't
  need to purge their `known_hosts` entry every time the app comes back
  up.

  The key file lives under `priv/ssh/ssh_host_rsa_key` by default;
  override the directory with `config :sshaudio, :ssh_host_key_dir`.
  """

  @behaviour :ssh_server_key_api

  require Logger

  @impl true
  def host_key(_algorithm, _daemon_options), do: {:ok, key()}

  @impl true
  def is_auth_key(_public_key, _user, _daemon_options), do: false

  defp key do
    case :persistent_term.get({__MODULE__, :key}, nil) do
      nil ->
        key = load_or_generate()
        :persistent_term.put({__MODULE__, :key}, key)
        key

      key ->
        key
    end
  end

  defp load_or_generate do
    path = key_path()

    case File.read(path) do
      {:ok, pem} ->
        decode(pem)

      {:error, :enoent} ->
        Logger.info("No SSH host key found at #{path}, generating one")
        generate_and_persist(path)

      {:error, reason} ->
        raise "could not read SSH host key at #{path}: #{:file.format_error(reason)}"
    end
  end

  defp generate_and_persist(path) do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, pem)
    File.chmod!(path, 0o600)

    key
  end

  defp decode(pem) do
    [entry] = :public_key.pem_decode(pem)
    :public_key.pem_entry_decode(entry)
  end

  defp key_path do
    dir = Application.get_env(:sshaudio, :ssh_host_key_dir, default_key_dir())
    Path.join(dir, "ssh_host_rsa_key")
  end

  defp default_key_dir do
    case :code.priv_dir(:sshaudio) do
      {:error, :bad_name} -> Path.join(File.cwd!(), "priv")
      priv_dir -> to_string(priv_dir)
    end
    |> Path.join("ssh")
  end
end
