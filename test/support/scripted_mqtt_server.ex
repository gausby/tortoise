defmodule Tortoise.Integration.ScriptedMqttServer do
  # A helper for testing interactions with a MQTT server by setting up
  # a process that act as the server and base its responses on a
  # script of commands that are either send `{:send, package}`, or
  # expected to be received `{:receive, package}`.

  @moduledoc false

  use GenServer

  defstruct transport: nil,
            server_socket: nil,
            script: [],
            client_pid: nil,
            client: nil,
            server_info: nil

  alias Tortoise.Package
  alias __MODULE__, as: State

  # Client API
  def start_link() do
    start_link([])
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def enact(pid, script) do
    GenServer.call(pid, {:enact, script})
  end

  # Server callbacks
  def init(opts) do
    transport = Keyword.get(opts, :transport, Tortoise.Transport.Tcp)

    transport_opts =
      case Keyword.get(opts, :opts, :default) do
        :default ->
          [:binary, active: false, packet: :raw]

        opts_list when is_list(opts_list) ->
          opts_list
      end

    case transport.listen(transport_opts) do
      {:ok, socket} ->
        {:ok, server_info} = transport.sockname(socket)

        initial_state = %__MODULE__{
          server_info: server_info,
          transport: transport,
          server_socket: socket
        }

        {:ok, initial_state}
    end
  end

  def handle_call({:enact, script}, {pid, _} = caller, %State{client_pid: pid} = state) do
    GenServer.reply(caller, {:ok, state.server_info})
    next_action(%State{state | script: state.script ++ script})
  end

  def handle_call({:enact, script}, {pid, _} = caller, state) do
    GenServer.reply(caller, {:ok, state.server_info})
    {:ok, client} = state.transport.accept(state.server_socket, 200)
    :ok = state.transport.accept_ack(client, 200)
    :ok = state.transport.setopts(client, active: :once)
    next_action(%State{state | client_pid: pid, script: script, client: client})
  end

  def handle_info(
        {transport, _, data},
        %State{script: [{:receive, expected} | script]} = state
      )
      when transport in [:tcp, :ssl] do
    case Package.decode(data) do
      ^expected ->
        send(state.client_pid, {__MODULE__, {:received, expected}})
        next_action(%State{state | script: script})

      otherwise ->
        {:stop, {:unexpected_package, otherwise}, state}
    end
  end

  def handle_info({transport, client}, %State{script: [], client: client} = state)
      when transport in [:tcp_closed, :ssl_closed] do
    {:stop, :normal, state}
  end

  defp next_action(%State{script: [{:send, package} | remaining]} = state) do
    # send the package right away
    encoded_package = Package.encode(package)
    :ok = state.transport.send(state.client, encoded_package)
    next_action(%State{state | script: remaining})
  end

  defp next_action(%State{script: [{:receive, _} | _]} = state) do
    :ok = state.transport.setopts(state.client, active: :once)
    # keep state and await for client to send data
    {:noreply, state}
  end

  defp next_action(%State{script: [:disconnect | remaining]} = state) do
    :ok = state.transport.close(state.client)
    {:ok, client} = state.transport.accept(state.server_socket, 200)
    :ok = state.transport.setopts(client, active: :once)
    next_action(%State{state | script: remaining, client: client})
  end

  defp next_action(%State{script: [:pause | remaining]} = state) do
    send(state.client_pid, {__MODULE__, :paused})

    receive do
      :continue ->
        next_action(%State{state | script: remaining})
    end
  end

  defp next_action(%State{script: []} = state) do
    send(state.client_pid, {__MODULE__, :completed})
    {:noreply, state}
  end
end
