alias SSHAudio.OutputSink.Server
alias SSHAudio.Library.Track

track = %Track{path: "/Users/nate/Downloads/init.mp3", artist: "sys", title: "frog", display: "frog"}

{:ok, state} = Server.init([])
{:ok, state} = Server.play(state, track, 40)
IO.inspect(state, label: "after play")
Process.sleep(300)

{:ok, state} = Server.pause(state)
IO.inspect(state.ipc, label: "ipc after pause")

{:ok, state} = Server.resume(state)
{:ok, state} = Server.set_volume(state, 90)
Process.sleep(200)

# verify volume actually changed via IPC get_property
:ok = :gen_tcp.send(state.ipc, ~s({"command":["get_property","volume"]}\n))
Process.sleep(50)
IO.inspect(:gen_tcp.recv(state.ipc, 0, 500), label: "volume readback")

{:ok, state} = Server.stop(state)
Process.sleep(200)
IO.inspect(File.exists?(state.socket_path || ""), label: "socket cleaned up")
IO.puts("no crash — done")
