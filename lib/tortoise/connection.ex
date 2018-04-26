defmodule Tortoise.Connection do
  @moduledoc false
  use GenServer

  require Logger

  defstruct [:socket, :monitor_ref, :connect, :server, :session, :subscriptions, :keep_alive]
  alias __MODULE__, as: State

  alias Tortoise.Connection
  alias Tortoise.Connection.{Inflight, Controller, Receiver}
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

    subscriptions =
      Keyword.get(opts, :subscriptions, [])
      |> Enum.into(%Tortoise.Package.Subscribe{})

    # @todo, validate that the driver is valid
    opts = Keyword.take(opts, [:client_id, :driver])
    initial = {server, connect, subscriptions, opts}
    GenServer.start_link(__MODULE__, initial, name: via_name(client_id))
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
  def init({{:tcp, _, _} = server, %Connect{} = connect, subscriptions, opts}) do
    expected_connack = %Connack{status: :accepted, session_present: false}

    with {^expected_connack, socket} <- do_connect(server, connect),
         {:ok, pid} = Connection.Supervisor.start_link(opts),
         :ok = Receiver.handle_socket(connect.client_id, {:tcp, socket}),
         :ok = Controller.update_connection_status(connect.client_id, :up) do
      monitor_ref = {socket, Port.monitor(socket)}

      if not Enum.empty?(subscriptions), do: send(self(), :subscribe)

      result = %State{
        session: pid,
        server: server,
        connect: connect,
        monitor_ref: monitor_ref,
        subscriptions: subscriptions
      }

      {:ok, reset_keep_alive(result)}
    else
      %Connack{status: {:refused, reason}} ->
        {:stop, {:connection_failed, reason}}

      {:error, {:protocol_violation, violation}} ->
        Logger.error("Protocol violation: #{inspect(violation)}")
        {:stop, :protocol_violation}
    end
  end

  def handle_info({:DOWN, ref, :port, port, :normal}, %State{monitor_ref: {port, ref}} = state) do
    connect = %Connect{state.connect | clean_session: false}
    :ok = Controller.update_connection_status(connect.client_id, :down)

    with {%Connack{status: :accepted} = connack, socket} <- do_connect(state.server, connect),
         :ok = Receiver.handle_socket(connect.client_id, {:tcp, socket}),
         :ok = Controller.update_connection_status(connect.client_id, :up) do
      monitor_ref = {socket, Port.monitor(socket)}

      case connack do
        %Connack{session_present: true} ->
          result = %State{state | connect: connect, monitor_ref: monitor_ref}
          {:noreply, reset_keep_alive(result)}

        %Connack{session_present: false} ->
          # delete inflight state ?
          if not Enum.empty?(state.subscriptions), do: send(self(), :subscribe)
          result = %State{state | connect: connect, monitor_ref: monitor_ref}
          {:noreply, reset_keep_alive(result)}
      end
    else
      %Connack{status: {:refused, reason}} ->
        {:stop, {:connection_failed, reason}}

      {:error, {:protocol_violation, violation}} ->
        Logger.error("Protocol violation: #{inspect(violation)}")
        {:stop, :protocol_violation}
    end
  end

  def handle_info(:subscribe, %State{subscriptions: subscriptions} = state) do
    client_id = state.connect.client_id

    case Enum.empty?(subscriptions) do
      true ->
        # nothing to subscribe to, just continue
        {:noreply, state}

      false ->
        # subscribe to the predefined topics
        {:ok, ref} = Inflight.track(client_id, {:outgoing, subscriptions})

        receive do
          {Tortoise, {{^client_id, ^ref}, _result}} ->
            # todo, handle topics that had errors like "access denied"
            # todo, handle topics that got a lower qos than expected
            {:noreply, state}
        after
          5000 ->
            {:stop, :subscription_timeout, state}
        end
    end
  end

  def handle_info(:ping, %State{} = state) do
    case Controller.ping_sync(state.connect.client_id, 5000) do
      {:ok, round_trip_time} ->
        Logger.debug("Ping: #{round_trip_time} μs")
        state = reset_keep_alive(state)
        {:noreply, state}

      {:stop, :timeout} ->
        {:stop, :ping_timeout, state}
    end
  end

  # Helpers
  defp reset_keep_alive(%State{keep_alive: nil} = state) do
    ref = Process.send_after(self(), :ping, state.connect.keep_alive * 1000)
    %State{state | keep_alive: ref}
  end

  defp reset_keep_alive(%State{keep_alive: previous_ref} = state) do
    # Cancel the previous timer, just in case one was already set
    _ = Process.cancel_timer(previous_ref)
    ref = Process.send_after(self(), :ping, state.connect.keep_alive * 1000)
    %State{state | keep_alive: ref}
  end

  defp do_connect({:tcp, host, port}, %Connect{} = connect) do
    tcp_opts = [:binary, packet: :raw, active: false]

    with {:ok, socket} <- :gen_tcp.connect(host, port, tcp_opts),
         :ok = :gen_tcp.send(socket, Package.encode(connect)),
         {:ok, packet} <- :gen_tcp.recv(socket, 4, 5000) do
      case Package.decode(packet) do
        %Connack{status: :accepted} = connack ->
          {connack, socket}

        %Connack{status: {:refused, _reason}} = connack ->
          connack

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
