defmodule SSHAudio.Library do
  @moduledoc """
  Scans a directory tree for music files and serves search queries
  against the result. Holds the scanned library in memory — call
  `set_path/1` to point it at a different directory (or rescan the
  same one) at runtime.
  """

  use GenServer

  require Logger

  alias SSHAudio.Library.Track

  @extensions ~w(.mp3 .flac .wav .ogg .m4a .aac .opus .wma .aiff)

  defstruct path: nil, tracks: []

  # Client API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec all() :: [Track.t()]
  def all, do: GenServer.call(__MODULE__, :all)

  @spec search(String.t()) :: [Track.t()]
  def search(query), do: GenServer.call(__MODULE__, {:search, query})

  @spec set_path(Path.t()) :: :ok
  def set_path(path), do: GenServer.call(__MODULE__, {:set_path, path})

  @doc "Recursively finds music files under `root` and builds a Track for each."
  @spec scan(Path.t()) :: [Track.t()]
  def scan(root) do
    music_files =
      root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&music_file?/1)

    total = length(music_files)
    Logger.info("Library: starting scan of #{total} music file(s) under #{root}")

    tracks =
      music_files
      |> Enum.with_index(1)
      |> Enum.map(fn {path, index} ->
        maybe_log_scan_progress(index, total, path)
        {path, index}
      end)
      |> Enum.chunk_every(max_concurrency())
      |> Enum.flat_map(fn batch ->
        batch
        |> Task.async_stream(
          fn {path, index} ->
            {index, build_track(path)}
          end,
          max_concurrency: max_concurrency(),
          ordered: false
        )
        |> Enum.map(fn {:ok, {index, track}} -> {index, track} end)
      end)
      |> Enum.sort_by(fn {index, _track} -> index end)
      |> Enum.map(fn {_index, track} -> track end)
      |> Enum.sort_by(& &1.display)

    Logger.info("Library: finished scan of #{length(tracks)} track(s) under #{root}")
    tracks
  end

  @doc "Filters `tracks` by a case-insensitive substring match on their display name."
  @spec search([Track.t()], String.t()) :: [Track.t()]
  def search(tracks, ""), do: tracks

  def search(tracks, query) do
    IO.inspect(tracks)
    needle = String.downcase(query)
    Enum.filter(tracks, &String.contains?(String.downcase(&1.display), needle))
  end

  # Server callbacks

  @impl true
  def init(opts) do
    {:ok, load(%__MODULE__{}, Keyword.get(opts, :path))}
  end

  @impl true
  def handle_call(:all, _from, state), do: {:reply, state.tracks, state}

  def handle_call({:search, query}, _from, state),
    do: {:reply, search(state.tracks, query), state}

  def handle_call({:set_path, path}, _from, state), do: {:reply, :ok, load(state, path)}

  defp load(state, nil) do
    Logger.info("Library: no path configured; skipping scan")
    %{state | path: nil, tracks: []}
  end

  defp load(state, path) do
    Logger.info("Library: scanning path #{inspect(path)}")

    if File.dir?(path) do
      tracks = scan(path)
      Logger.info("Library: scanned #{length(tracks)} tracks from #{path}")
      %{state | path: path, tracks: tracks}
    else
      Logger.warning("Library: path #{inspect(path)} is not a directory; skipping scan")
      %{state | path: nil, tracks: []}
    end
  end

  defp music_file?(path) do
    ext = path |> Path.extname() |> String.downcase()
    File.regular?(path) and ext in @extensions
  end

  defp maybe_log_scan_progress(index, total, path) do
    if index == 1 or index == total or rem(index, 50) == 0 do
      Logger.info("Library scan progress: #{index}/#{total} #{Path.basename(path)}")
    end
  end

  defp max_concurrency do
    System.schedulers_online() |> max(2) |> min(8)
  end

  defp build_track(path) do
    tags = probe_tags(path)
    {artist, title} = artist_title(tags, path)
    display = if artist, do: "#{artist} — #{title}", else: title

    %Track{
      path: path,
      title: title,
      artist: artist,
      album: tag(tags, "album"),
      album_img: extract_album_img(path),
      display: display
    }
  end

  defp artist_title(tags, path) do
    case tag(tags, "title") do
      title when is_binary(title) -> {tag(tags, "artist"), title}
      nil -> filename_artist_title(path)
    end
  end

  defp filename_artist_title(path) do
    base = path |> Path.basename() |> Path.rootname()

    case String.split(base, ~r/\s+-\s+/, parts: 2) do
      [artist, title] -> {artist, title}
      [title] -> {nil, title}
    end
  end

  # Reads container-level tags (title/artist/album/...) via a fast direct
  # parser for MP3 files and falls back to `ffprobe` for everything else.
  # Returns `%{}` if no compatible metadata is available so callers can fall
  # back to filename-based guessing.
  defp probe_tags(path) do
    case Path.extname(path) |> String.downcase() do
      ".mp3" -> probe_mp3_tags(path)
      _ -> probe_ffprobe_tags(path)
    end
  end

  defp probe_mp3_tags(path) do
    case Id3vx.parse_file(path) do
      {:ok, tag} ->
        %{
          "title" => read_tag_value(tag, "TIT2"),
          "artist" => read_tag_value(tag, "TPE1"),
          "album" => read_tag_value(tag, "TALB")
        }

      _ ->
        %{}
    end
  end

  defp probe_ffprobe_tags(path) do
    with bin when not is_nil(bin) <- System.find_executable("ffprobe"),
         args = ["-v", "quiet", "-print_format", "json", "-show_entries", "format_tags", path],
         {json, 0} <- System.cmd(bin, args, stderr_to_stdout: false),
         {:ok, %{"format" => %{"tags" => tags}}} <- JSON.decode(json) do
      tags
    else
      _ -> %{}
    end
  end

  defp read_tag_value(tag, frame_id) do
    tag
    |> tag_value(frame_id)
    |> case do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp tag_value(tag, frame_id) when is_map(tag) do
    case Map.get(tag, :frames) do
      frames when is_list(frames) ->
        Enum.find_value(frames, fn
          %{id: ^frame_id, data: %_{text: text}} when is_binary(text) -> text
          %{id: ^frame_id, data: %_{text: text}} when is_list(text) -> List.first(text)
          %{id: ^frame_id, text: [value | _]} -> value
          %{id: ^frame_id, value: value} -> value
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp tag_value(_tag, _frame_id), do: nil

  # Tag keys are case-inconsistent across containers (e.g. FLAC/Ogg tend
  # to use uppercase, MP4/MP3 lowercase), so look up case-insensitively.
  defp tag(tags, key) when is_map(tags) do
    Enum.find_value(tags, fn {k, v} -> String.downcase(k) == key && v end)
  end

  # Extracts embedded cover art (the "attached pic" stream ID3/FLAC/etc.
  # carry alongside the audio) as raw image bytes via `ffmpeg`. Returns
  # `nil` if there's no such stream, or `ffmpeg`/`ffprobe` is missing.
  defp extract_album_img(path) do
    if has_attached_pic?(path) do
      case System.find_executable("ffmpeg") do
        nil ->
          nil

        bin ->
          args = ["-v", "quiet", "-i", path, "-an", "-c:v", "copy", "-f", "image2pipe", "-"]

          case System.cmd(bin, args, stderr_to_stdout: false) do
            {image, 0} when byte_size(image) > 0 -> image
            _ -> nil
          end
      end
    end
  end

  defp has_attached_pic?(path) do
    with bin when not is_nil(bin) <- System.find_executable("ffprobe"),
         args = [
           "-v",
           "quiet",
           "-print_format",
           "json",
           "-show_entries",
           "stream_disposition=attached_pic",
           path
         ],
         {json, 0} <- System.cmd(bin, args, stderr_to_stdout: false),
         {:ok, %{"streams" => streams}} <- JSON.decode(json) do
      Enum.any?(streams, &(&1["disposition"]["attached_pic"] == 1))
    else
      _ -> false
    end
  end
end
