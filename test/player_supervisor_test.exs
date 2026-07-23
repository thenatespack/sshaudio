defmodule SSHAudio.SSH.ChannelTest do
  use ExUnit.Case, async: true

  alias SSHAudio.SSH.Channel

  test "all SSH connections share the same player identity" do
    assert Channel.shared_player_id() == "shared"
  end
end
