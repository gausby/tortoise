defmodule Tortoise.Connection do
  @moduledoc false
  use GenServer

  require Logger

  defstruct [:socket, :monitor_ref, :connect, :server, :session]
  alias __MODULE__, as: State

  alias Tortoise.Connection
  alias Tortoise.Connection.Receiver
  alias Tortoise.Package
  alias Tortoise.Package.{Connect, Connack}

  def start_link(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    server = Keyword.fetch!(opts, :server)

    connect = %Package.Connect{
      client_id: client_id,
      user_name: Keyword.get(opts, :user_name),
      password: Keyword.get(opts, :password),
      keep_alive: Keyword.get(opts, :keep_alive, 60),
      will: Keyword.get(opts, :last_will),
      # if we re-spawn from here it means our state is gone
      clean_session: true
    }

    # @todo, validate that the driver is valid
    opts = Keyword.take(opts, [:client_id, :keep_alive, :driver])

    GenServer.start_link(__MODULE__, {server, connect, opts}, name: via_name(client_id))
  end

  def via_name(pid) when is_pid(pid), do: pid

  def via_name(client_id) do
    {:via, Registry, reg_name(client_id)}
  end

  def reg_name(client_id) do
    {Registry.Tortoise, {__MODULE__, client_id}}
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  # Callbacks
  def init({{:tcp, _, _} = server, %Connect{} = connect, opts}) do
    expected_connack = %Connack{status: :accepted, session_present: false}

    with {:ok, socket, ^expected_connack} <- do_connect(server, connect),
         {:ok, pid} = Connection.Supervisor.start_link(opts),
         :ok = Receiver.handle_socket(connect.client_id, {:tcp, socket}) do
      monitor_ref = {socket, Port.monitor(socket)}
      {:ok, %State{session: pid, server: server, connect: connect, monitor_ref: monitor_ref}}
    else
      {:error, %Connack{status: {:refused, reason}}} ->
        {:stop, {:connection_failed, reason}}

      {:error, {:protocol_violation, violation}} ->
        Logger.error("Protocol violation: #{inspect(violation)}")
        {:stop, :protocol_violation}
    end
  end

  def handle_info({:DOWN, ref, :port, port, :normal}, %State{monitor_ref: {port, ref}} = state) do
    connect = %Connect{state.connect | clean_session: false}

    with {:ok, socket, connack} <- do_connect(state.server, connect),
         :ok = Receiver.handle_socket(connect.client_id, {:tcp, socket}) do
      monitor_ref = {socket, Port.monitor(socket)}

      case %Connack{status: :accepted} = connack do
        %Connack{session_present: true} ->
          {:noreply, %State{state | connect: connect, monitor_ref: monitor_ref}}

        %Connack{session_present: false} ->
          # delete inflight state ?
          {:noreply, %State{state | connect: connect, monitor_ref: monitor_ref}}
      end
    else
      {:error, %Connack{status: {:refused, reason}}} ->
        {:stop, {:connection_failed, reason}}

      {:error, {:protocol_violation, violation}} ->
        Logger.error("Protocol violation: #{inspect(violation)}")
        {:stop, :protocol_violation}
    end
  end

  # Helpers

  defp do_connect({:tcp, host, port}, %Connect{} = connect) do
    tcp_opts = [:binary, packet: :raw, active: false]

    with {:ok, socket} <- :gen_tcp.connect(host, port, tcp_opts),
         :ok = :gen_tcp.send(socket, Package.encode(connect)),
         {:ok, packet} <- :gen_tcp.recv(socket, 4, 5000) do
      case Package.decode(packet) do
        %Connack{status: :accepted} = connack ->
          {:ok, socket, connack}

        %Connack{status: {:refused, _reason}} = connack ->
          {:error, connack}

        other ->
          violation = %{expected: Connect, got: other}
          {:error, {:protocol_violation, violation}}
      end
    else
      {:error, :econnrefused} ->
        {:error, {:connection_refused, host, port}}
    end
  end
end
