defmodule SSHAudio.TUI.Widgets do
  @moduledoc """
  Small composable widgets built on top of `SSHAudio.TUI.Buffer`.
  """

  alias SSHAudio.TUI.Buffer

  @doc """
  Draws a bordered panel, optionally with a title embedded in the top
  border. `width`/`height` include the border itself.
  """
  @spec panel(Buffer.t(), integer(), integer(), pos_integer(), pos_integer(), keyword()) ::
          Buffer.t()
  def panel(buffer, row, col, width, height, opts \\ []) do
    style = Keyword.get(opts, :style, [])
    title = Keyword.get(opts, :title)

    buffer = Buffer.box(buffer, row, col, width, height, style)

    case title do
      nil -> buffer
      title -> Buffer.put_string(buffer, row, col + 2, " #{title} ", style)
    end
  end

  @doc """
  Draws a horizontal progress bar `width` cells wide. `ratio` (0.0..1.0,
  clamped) is the filled fraction.
  """
  @spec progress_bar(Buffer.t(), integer(), integer(), pos_integer(), float(), keyword()) ::
          Buffer.t()
  def progress_bar(buffer, row, col, width, ratio, opts \\ []) when width >= 1 do
    style = Keyword.get(opts, :style, [])
    empty_style = Keyword.get(opts, :empty_style, [:faint])
    filled = ratio |> max(0.0) |> min(1.0) |> Kernel.*(width) |> round()

    Enum.reduce(0..(width - 1), buffer, fn i, buffer ->
      if i < filled do
        Buffer.put(buffer, row, col + i, "█", style)
      else
        Buffer.put(buffer, row, col + i, "░", empty_style)
      end
    end)
  end

  @doc """
  Renders `path` as terminal art via the external `chafa` binary and
  stamps it at (`row`, `col`) as a `width`x`height` grid of cells.
  Falls back to a plain placeholder line if `chafa` isn't on PATH or
  the image can't be decoded.
  """
  @spec img_preview(Buffer.t(), integer(), integer(), pos_integer(), pos_integer(), String.t()) ::
          Buffer.t()
  def img_preview(buffer, row, col, width, height, path) do
    case render_chafa(path, width, height) do
      {:ok, art} -> Buffer.put_raw(buffer, row, col, art)
      :error -> Buffer.put_string(buffer, row, col, "(no album art)", [:faint])
    end
  end

  @doc """
  Like `img_preview/6`, but takes raw image bytes (e.g. `Track.album_img`)
  instead of a file path, since `chafa` needs a path to read from. Renders
  the placeholder if `image_data` is `nil`.
  """
  @spec img_preview_data(Buffer.t(), integer(), integer(), pos_integer(), pos_integer(), binary() | nil) ::
          Buffer.t()
  def img_preview_data(buffer, row, col, _width, _height, nil) do
    Buffer.put_string(buffer, row, col, "(no album art)", [:faint])
  end

  def img_preview_data(buffer, row, col, width, height, image_data) when is_binary(image_data) do
    path = Path.join(System.tmp_dir!(), "ssh_audio_art_#{:erlang.unique_integer([:positive])}")

    try do
      File.write!(path, image_data)
      img_preview(buffer, row, col, width, height, path)
    after
      File.rm(path)
    end
  end

  defp render_chafa(path, width, height) do
    case System.find_executable("chafa") do
      nil ->
        :error

      bin ->
        args = [
          "--format=symbols",
          "--colors=full",
          "--size=#{width}x#{height}",
          "--polite=on",
          path
        ]

        case System.cmd(bin, args, stderr_to_stdout: true) do
          {art, 0} -> {:ok, art}
          _ -> :error
        end
    end
  end

  @doc "Draws a list of lines starting at `row`, one per line, indented by `col`."
  @spec list(Buffer.t(), integer(), integer(), [String.t()], keyword()) :: Buffer.t()
  def list(buffer, row, col, lines, opts \\ []) do
    style = Keyword.get(opts, :style, [])

    lines
    |> Enum.with_index()
    |> Enum.reduce(buffer, fn {line, i}, buffer ->
      Buffer.put_string(buffer, row + i, col, line, style)
    end)
  end
end
