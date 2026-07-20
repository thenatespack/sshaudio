defmodule SSHAudio.TUI.Buffer do
  @moduledoc """
  A virtual screen: a grid of styled cells that gets built up with plain
  function calls and rendered to ANSI iodata in one shot at the end.

  This exists because sessions don't own a real tty (SSH channel bytes
  are just forwarded by `SSHAudio.SSH.Channel`), so termbox-based TUI
  libraries like Ratatouille can't be used directly — each connection
  needs its own independent virtual screen instead of one process
  owning the terminal.
  """

  defstruct [:width, :height, cells: %{}, overlays: []]

  @type style :: [atom()]
  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          cells: map(),
          overlays: [{pos_integer(), pos_integer(), iodata()}]
        }

  @blank {" ", []}

  @spec new(pos_integer(), pos_integer()) :: t()
  def new(width, height), do: %__MODULE__{width: width, height: height, cells: %{}}

  @spec put(t(), integer(), integer(), String.t(), style()) :: t()
  def put(buffer, row, col, char, style \\ [])

  def put(%__MODULE__{width: width, height: height} = buffer, row, col, char, style)
      when row in 1..height//1 and col in 1..width//1 do
    %{buffer | cells: Map.put(buffer.cells, {row, col}, {char, style})}
  end

  def put(buffer, _row, _col, _char, _style), do: buffer

  @doc """
  Stamps pre-rendered ANSI content (e.g. `chafa` output) at (`row`,
  `col`), verbatim and outside the styled-cell grid — each `\\n`-
  separated line of `raw` is positioned on its own screen row via
  cursor movement rather than merged into `cells`. Use this for
  content whose styling can't be expressed as a plain atom list (24-bit
  color, multi-line pre-formatted art, etc).
  """
  @spec put_raw(t(), integer(), integer(), iodata()) :: t()
  def put_raw(%__MODULE__{width: width, height: height} = buffer, row, col, raw)
      when row in 1..height//1 and col in 1..width//1 do
    %{buffer | overlays: [{row, col, raw} | buffer.overlays]}
  end

  def put_raw(buffer, _row, _col, _raw), do: buffer

  @spec put_string(t(), integer(), integer(), String.t(), style()) :: t()
  def put_string(buffer, row, col, string, style \\ []) do
    string
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.reduce(buffer, fn {char, offset}, buffer ->
      put(buffer, row, col + offset, char, style)
    end)
  end

  @spec hline(t(), integer(), integer(), non_neg_integer(), style()) :: t()
  def hline(buffer, row, col, len, style \\ [])
  def hline(buffer, _row, _col, len, _style) when len <= 0, do: buffer

  def hline(buffer, row, col, len, style) do
    Enum.reduce(0..(len - 1), buffer, fn i, buffer -> put(buffer, row, col + i, "─", style) end)
  end

  @spec vline(t(), integer(), integer(), non_neg_integer(), style()) :: t()
  def vline(buffer, row, col, len, style \\ [])
  def vline(buffer, _row, _col, len, _style) when len <= 0, do: buffer

  def vline(buffer, row, col, len, style) do
    Enum.reduce(0..(len - 1), buffer, fn i, buffer -> put(buffer, row + i, col, "│", style) end)
  end

  @doc "Draws a box border. `width`/`height` include the border itself."
  @spec box(t(), integer(), integer(), pos_integer(), pos_integer(), style()) :: t()
  def box(buffer, row, col, width, height, style \\ []) when width >= 2 and height >= 2 do
    buffer
    |> put(row, col, "┌", style)
    |> put(row, col + width - 1, "┐", style)
    |> put(row + height - 1, col, "└", style)
    |> put(row + height - 1, col + width - 1, "┘", style)
    |> hline(row, col + 1, width - 2, style)
    |> hline(row + height - 1, col + 1, width - 2, style)
    |> vline(row + 1, col, height - 2, style)
    |> vline(row + 1, col + width - 1, height - 2, style)
  end

  @doc "Renders the buffer to iodata: clear screen, home cursor, styled content."
  @spec to_iodata(t()) :: iodata()
  def to_iodata(%__MODULE__{height: height} = buffer) do
    content =
      1..height
      |> Enum.map(&row_ansidata(buffer, &1))
      |> Enum.intersperse("\r\n")

    [
      IO.ANSI.clear(),
      IO.ANSI.cursor(1, 1),
      IO.ANSI.format(content, true),
      overlays_iodata(buffer.overlays),
      IO.ANSI.reset()
    ]
  end

  # Overlays are stored newest-first (each put_raw prepends); render in
  # call order so later calls draw on top of earlier ones.
  defp overlays_iodata(overlays) do
    overlays
    |> Enum.reverse()
    |> Enum.map(fn {row, col, raw} ->
      raw
      |> IO.iodata_to_binary()
      |> String.split("\n", trim: true)
      |> Enum.with_index()
      |> Enum.map(fn {line, i} -> [IO.ANSI.cursor(row + i, col), line] end)
    end)
  end

  defp row_ansidata(buffer, row) do
    1..buffer.width
    |> Enum.map(&Map.get(buffer.cells, {row, &1}, @blank))
    |> Enum.chunk_by(fn {_char, style} -> style end)
    |> Enum.flat_map(fn [{_char, style} | _] = chunk ->
      text = chunk |> Enum.map(fn {char, _style} -> char end) |> Enum.join()
      style ++ [text, :reset]
    end)
  end
end
