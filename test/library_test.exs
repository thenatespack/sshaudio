defmodule SSHAudio.LibraryTest do
  use ExUnit.Case, async: false

  alias SSHAudio.Library

  test "scan reads ID3 metadata from MP3 files" do
    temp_dir =
      Path.join(System.tmp_dir!(), "sshaudio-library-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)

    on_exit(fn -> File.rm_rf!(temp_dir) end)

    tag =
      Id3vx.Tag.create(3)
      |> Id3vx.Tag.add_text_frame("TIT2", "Hello World")
      |> Id3vx.Tag.add_text_frame("TPE1", "Test Artist")
      |> Id3vx.Tag.add_text_frame("TALB", "Test Album")

    file_path = Path.join(temp_dir, "song.mp3")
    File.write!(file_path, Id3vx.encode_tag(tag) <> <<0, 1, 2, 3, 4, 5>>)

    [track] = Library.scan(temp_dir)

    assert track.title == "Hello World"
    assert track.artist == "Test Artist"
    assert track.album == "Test Album"
  end

  test "scan can expose tracks incrementally while it is running" do
    temp_dir =
      Path.join(System.tmp_dir!(), "sshaudio-library-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)

    on_exit(fn -> File.rm_rf!(temp_dir) end)

    file_path = Path.join(temp_dir, "song.mp3")
    File.write!(file_path, <<0, 1, 2, 3, 4, 5>>)

    name = String.to_atom("test_library_#{System.unique_integer([:positive])}")
    assert {:ok, _pid} = start_supervised({SSHAudio.Library, path: temp_dir, name: name})
    assert [] == GenServer.call(name, :all)

    assert :ok = GenServer.cast(name, {:scan_and_update, temp_dir})
    assert [%{path: ^file_path}] = GenServer.call(name, :all)
  end
end
