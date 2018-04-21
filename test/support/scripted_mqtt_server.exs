defmodule Tortoise.Integration.ScriptedMqttServer do
  # A helper for testing interactions with a MQTT server by setting up
  # a process that act as the server and base its responses on a
  # script of commands that are either send `{:send, package}`, or
  # expected to be received `{:receive, package}`.

  @moduledoc false

  use GenServer

  defstruct server_socket: nil, script: [], client_pid: nil, client: nil, server_info: nil

  alias Tortoise.Package
  alias __MODULE__, as: State

  # Client API
  def start_link() do
    GenServer.start_link(__MODULE__, :na)
  end

  def enact(pid, script) do
    GenServer.call(pid, {:enact, script})
  end

  # Server callbacks
  def init(:na) do
    case :gen_tcp.listen(0, [:binary, active: false]) do
      {:ok, socket} ->
        {:ok, server_info} = :inet.sockname(socket)
        {:ok, %__MODULE__{server_info: server_info, server_socket: socket}}
    end
  end

  def handle_call({:enact, script}, {pid, _} = caller, state) do
    GenServer.reply(caller, {:ok, state.server_info})
    {:ok, client} = :gen_tcp.accept(state.server_socket, 200)
    :ok = :inet.setopts(client, active: :once)
    next_action(%State{state | client_pid: pid, script: script, client: client})
  end

  def handle_info({:tcp, _, tcp_data}, %State{script: [{:receive, expected} | script]} = state) do
    case Package.decode(tcp_data) do
      ^expected ->
        send(state.client_pid, {__MODULE__, {:received, expected}})
        next_action(%State{state | script: script})

      otherwise ->
        throw({:unexpected_package, otherwise})
    end
  end

  defp next_action(%State{script: [{:send, package} | remaining]} = state) do
    # send the package right away
    encoded_package = Package.encode(package)
    :ok = :gen_tcp.send(state.client, encoded_package)
    next_action(%State{state | script: remaining})
  end

  defp next_action(%State{script: [{:receive, _} | _]} = state) do
    :ok = :inet.setopts(state.client, active: :once)
    # keep state and await for client to send data
    {:noreply, state}
  end

  defp next_action(%State{script: [:disconnect | remaining]} = state) do
    :ok = :gen_tcp.close(state.client)
    {:ok, client} = :gen_tcp.accept(state.server_socket, 200)
    :ok = :inet.setopts(client, active: :once)
    next_action(%State{state | script: remaining, client: client})
  end

  defp next_action(%State{script: []} = state) do
    send(state.client_pid, {__MODULE__, :completed})
    {:noreply, state}
  end
end
