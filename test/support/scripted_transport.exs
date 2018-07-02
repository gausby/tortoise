defmodule Tortoise.Integration.ScriptedTransport do
  @moduledoc """
  The `ScriptedTransport` is a GenServer that implement the
  `Tortoise.Transport`-behaviour. It can be given a list of expected
  packages, and the packages it should respond with like this:

      script = [
        {:expect, %Package.Connect{client_id: "Test"}},
        {:dispatch, %Package.Connack{status: :accepted}}
      ]

      {:ok, _} = ScriptedTransport.start_link({'localhost', 1883}, script: script)

  This will start a server which `Tortoise.Connection` can connect to
  like this:

      {:ok, _} = Tortoise.Connection.start_link(
        client_id: "Test",
        server: {ScriptedTransport, host: 'localhost', port: 1883},
        handler: {Tortoise.Handler.Logger, []}
      )

  While the `Tortoise.Transport.Tcp`-transport is recommenced for most
  test cases this transport can be used to simulate a network
  connection sending a specific error code at a given time; a test
  case where we need the broker to send back `{:error, :nxdomain}`
  could look like this:

      script = [
        {:refute_connection, {:error, :nxdomain}}
      ]

      {:ok, _} = ScriptedTransport.start_link({'localhost', 1883}, script: script)

  Which will send a non-existent domain error to the
  `Tortoise.Connection` when a connection is established.

  The transport will shutdown if it get an unexpected package.
  """

  import Kernel, except: [send: 2]

  @behaviour Tortoise.Transport
  alias Tortoise.Transport
  alias __MODULE__, as: State

  @enforce_keys [:script]
  defstruct [
    :script,
    :client,
    :host,
    :port,
    :opts,
    :stats,
    :status,
    :controlling_process,
    :buffer
  ]

  use GenServer

  # Client API
  def start_link({host, port}, opts) do
    name = Tortoise.Registry.via_name(__MODULE__, {host, port})

    defaults = [
      host: host,
      port: port,
      buffer: "",
      stats: []
    ]

    state = struct(State, Keyword.merge(defaults, opts))

    GenServer.start_link(__MODULE__, state, name: name)
  end

  defp via_name({host, port}) do
    Tortoise.Registry.via_name(__MODULE__, {host, port})
  end

  @impl true
  def new(opts) do
    {host, opts} = Keyword.pop(opts, :host)
    {port, opts} = Keyword.pop(opts, :port, 1883)
    %Transport{type: __MODULE__, host: host, port: port, opts: opts}
  end

  @impl true
  def connect(host, port, opts, timeout) do
    GenServer.call(via_name({host, port}), {:connect, opts, timeout})
  end

  @impl true
  def close(socket) do
    GenServer.call(socket, :close)
  end

  @impl true
  def controlling_process(socket, pid) do
    GenServer.call(socket, {:controlling_process, pid})
  end

  @impl true
  def getopts(socket, opts) do
    GenServer.call(socket, {:getopts, opts})
  end

  @impl true
  def getstat(socket) do
    GenServer.call(socket, :getstat)
  end

  @impl true
  def getstat(socket, opt_names) do
    GenServer.call(socket, {:getstat, opt_names})
  end

  @impl true
  def peername(socket) do
    GenServer.call(socket, :peername)
  end

  @impl true
  def sockname(socket) do
    GenServer.call(socket, :sockname)
  end

  @impl true
  def recv(socket, length, timeout) do
    GenServer.call(socket, {:recv, length, timeout})
  end

  @impl true
  def send(socket, packet) do
    GenServer.call(socket, {:send, packet})
  end

  @impl true
  def setopts(socket, opts) do
    GenServer.call(socket, {:setopts, opts})
  end

  @impl true
  def shutdown(socket, mode) when mode in [:read, :write, :read_write] do
    GenServer.call(socket, {:shutdown, mode})
  end

  @impl true
  def listen(_opts) do
    {:error, :not_implemented}
  end

  @impl true
  def accept(_socket, _timeout) do
    {:error, :not_implemented}
  end

  @impl true
  def accept_ack(_client_socket, _timeout) do
    {:error, :not_implemented}
  end

  # Server callbacks
  @impl true
  def init(%State{script: script} = state) when is_list(script) do
    {:ok, state}
  end

  def init(_) do
    {:stop, :no_script_specified}
  end

  @impl true
  def handle_call(_, _, %State{status: :closed} = state) do
    {:stop, :data_received_after_close, state}
  end

  def handle_call(
        {:connect, _opts, _timeout},
        _,
        %State{client: nil, script: [{:refute_connection, reason} | remaining]} = state
      ) do
    {:reply, reason, %State{state | script: remaining}}
  end

  def handle_call({:connect, opts, _timeout}, {client_pid, _ref}, %State{client: nil} = state) do
    {:reply, {:ok, self()}, %State{state | client: client_pid, status: :open, opts: opts}}
  end

  def handle_call({:connect, _, _}, _from, state) do
    {:stop, :already_connected, state}
  end

  def handle_call(:close, _, state) do
    {:reply, :ok, %State{state | status: :closed}}
  end

  def handle_call({:shutdown, _mode}, _from, %State{} = state) do
    # todo: mode in [:read, :write, :read_write]
    {:reply, :ok, state}
  end

  def handle_call({:controlling_process, pid}, _, %State{} = state) do
    {:reply, :ok, %State{state | controlling_process: pid}}
  end

  # receive packages from the MQTT Client
  def handle_call({:send, packet}, _, %State{script: [{:expect, expected} | remaining]} = state) do
    case Tortoise.Package.decode(packet) do
      ^expected ->
        {:reply, :ok, setup_next(%State{state | script: remaining})}

      unexpected ->
        {:stop, {:unexpected_data, [got: unexpected, expected: expected]}, state}
    end
  end

  def handle_call(
        {:recv, length, _timeout},
        {client_pid, _},
        %State{client: client_pid, buffer: buffer} = state
      )
      when byte_size(buffer) >= length do
    <<msg::binary-size(length), remaining::binary>> = buffer
    {:reply, {:ok, msg}, %State{state | buffer: remaining}}
  end

  def handle_call({:recv, _length, _timeout}, {other, _ref}, %State{client: client} = state)
      when client != other do
    {:stop, :not_the_controlling_process, state}
  end

  def handle_call({:setopts, opts}, _from, %State{} = state) do
    {:reply, :ok, %State{state | opts: Keyword.merge(state.opts, opts)}}
  end

  def handle_call({:getopts, _opts}, _, %State{} = state) do
    {:reply, :na, state}
  end

  def handle_call(:getstat, _, %State{} = state) do
    {:reply, state.stats, state}
  end

  def handle_call(:peername, _, %State{} = state) do
    peername = {state.host, state.port}
    {:reply, {:ok, peername}, state}
  end

  def handle_call(:sockname, _, %State{} = state) do
    sockname = {state.host, state.port}
    {:reply, {:ok, sockname}, state}
  end

  def handle_call({:getstat, opts}, _, %State{} = state) do
    {:reply, Keyword.take(state.stats, opts), state}
  end

  defp setup_next(%State{script: [{:dispatch, package} | remaining]} = state) do
    data = IO.iodata_to_binary(Tortoise.Package.encode(package))
    buffer = state.buffer <> data
    %State{state | script: remaining, buffer: buffer}
  end
end
