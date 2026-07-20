defmodule SSHAudio.Library.Track do
  @moduledoc """
  A music file discovered on disk. Metadata is read from the file's
  own tags via `ffprobe`/`ffmpeg` where available, falling back to
  guessing from the filename (`Artist - Title.ext`) otherwise.
  """

  @enforce_keys [:path, :title, :display]
  defstruct [:path, :title, :artist, :album, :album_img, :display]

  @type t :: %__MODULE__{
          path: String.t(),
          title: String.t(),
          artist: String.t() | nil,
          album: String.t() | nil,
          album_img: binary() | nil,
          display: String.t()
        }
end
