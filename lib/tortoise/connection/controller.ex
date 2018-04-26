defmodule Tortoise.Connection.Controller do
  @moduledoc false

  alias Tortoise.Package
  alias Tortoise.Connection.{Transmitter, Inflight}
  alias Tortoise.Driver

  alias Tortoise.Package.{
    Connect,
    Connack,
    Disconnect,
    Publish,
    Puback,
    Pubrec,
    Pubrel,
    Pubcomp,
    Subscribe,
    Suback,
    Unsubscribe,
    Unsuback,
    Pingreq,
    Pingresp
  }

  use GenServer

  @enforce_keys [:client_id, :driver]
  defstruct client_id: nil,
            ping: :queue.new(),
            status: :down,
            driver: %Driver{module: Tortoise.Driver.Default, initial_args: []}

  alias __MODULE__, as: State

  # Client API
  def start_link(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    driver = Driver.new(Keyword.fetch!(opts, :driver))

    init_state = %__MODULE__{
      client_id: client_id,
      driver: driver
    }

    GenServer.start_link(__MODULE__, init_state, name: via_name(client_id))
  end

  defp via_name(pid) when is_pid(pid), do: pid

  defp via_name(client_id) do
    {:via, Registry, reg_name(client_id)}
  end

  def reg_name(client_id) do
    {Registry.Tortoise, {__MODULE__, client_id}}
  end

  def stop(client_id) do
    GenServer.stop(via_name(client_id))
  end

  def ping(client_id) do
    ref = make_ref()
    :ok = GenServer.cast(via_name(client_id), {:ping, {self(), ref}})
    {:ok, ref}
  end

  def ping_sync(client_id, timeout \\ :infinity) do
    {:ok, ref} = ping(client_id)

    receive do
      {Tortoise, {:ping_response, ^ref, round_trip_time}} ->
        {:ok, round_trip_time}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  def handle_incoming(client_id, package) do
    GenServer.cast(via_name(client_id), {:incoming, package})
  end

  def handle_result(_client_id, %Inflight.Track{caller: nil}) do
    :ok
  end

  def handle_result(client_id, %Inflight.Track{
        type: Package.Publish,
        caller: {pid, ref},
        result: :ok
      }) do
    send(pid, {Tortoise, {{client_id, ref}, :ok}})
    :ok
  end

  def handle_result(client_id, %Inflight.Track{caller: {pid, ref}, result: result} = track) do
    send(pid, {Tortoise, {{client_id, ref}, result}})
    GenServer.cast(via_name(client_id), {:result, track})
  end

  def update_connection_status(client_id, status) when status in [:up, :down] do
    GenServer.cast(via_name(client_id), {:update_connection_status, status})
  end

  # Server callbacks
  def init(%__MODULE__{} = opts) do
    case run_init_callback(opts) do
      {:ok, %__MODULE__{} = initial_state} ->
        {:ok, initial_state}
    end
  end

  def terminate(reason, state) do
    _ignored = run_terminate_callback(reason, state)
    :ok
  end

  def handle_cast({:incoming, <<package::binary>>}, state) do
    package
    |> Package.decode()
    |> handle_package(state)
  end

  # allow for passing in already decoded packages into the controller,
  # this allow us to test the controller without having to pass in
  # binaries
  def handle_cast({:incoming, %{:__META__ => _} = package}, state) do
    handle_package(package, state)
  end

  def handle_cast({:ping, caller}, state) do
    time = System.monotonic_time(:microsecond)
    :ok = Transmitter.cast(state.client_id, %Package.Pingreq{})
    ping = :queue.in({caller, time}, state.ping)
    {:noreply, %State{state | ping: ping}}
  end

  def handle_cast(
        {:result, %Inflight.Track{type: Package.Subscribe} = track},
        state
      ) do
    case run_subscription_callback(track, state) do
      {:ok, state} ->
        {:noreply, state}
    end
  end

  def handle_cast(
        {:result, %Inflight.Track{type: Package.Unsubscribe} = track},
        state
      ) do
    case run_subscription_callback(track, state) do
      {:ok, state} ->
        {:noreply, state}
    end
  end

  def handle_cast({:update_connection_status, same}, %State{status: same} = state) do
    {:noreply, state}
  end

  def handle_cast({:update_connection_status, new_status}, %State{} = state) do
    case run_connection_callback(new_status, %State{state | status: new_status}) do
      {:ok, state} ->
        {:noreply, state}
    end
  end

  # QoS LEVEL 0 ========================================================
  # commands -----------------------------------------------------------
  defp handle_package(%Publish{qos: 0, dup: false} = publish, state) do
    # dispatch message
    case run_publish_callback(publish, state) do
      {:ok, state} ->
        {:noreply, state}

        # handle stop
    end
  end

  # QoS LEVEL 1 ========================================================
  # commands -----------------------------------------------------------
  defp handle_package(%Publish{qos: 1} = publish, state) do
    :ok = Inflight.track(state.client_id, {:incoming, publish})
    # dispatch message
    case run_publish_callback(publish, state) do
      {:ok, state} ->
        {:noreply, state}
    end
  end

  # response -----------------------------------------------------------
  defp handle_package(%Puback{} = puback, state) do
    :ok = Inflight.update(state.client_id, {:received, puback})
    {:noreply, state}
  end

  # QoS LEVEL 2 ========================================================
  # commands -----------------------------------------------------------
  defp handle_package(%Publish{qos: 2, dup: false} = publish, state) do
    :ok = Inflight.track(state.client_id, {:incoming, publish})

    case run_publish_callback(publish, state) do
      {:ok, state} ->
        {:noreply, state}
    end
  end

  defp handle_package(%Pubrel{} = pubrel, state) do
    :ok = Inflight.update(state.client_id, {:received, pubrel})
    {:noreply, state}
  end

  # response -----------------------------------------------------------
  defp handle_package(%Pubrec{} = pubrec, state) do
    :ok = Inflight.update(state.client_id, {:received, pubrec})
    {:noreply, state}
  end

  defp handle_package(%Pubcomp{} = pubcomp, state) do
    :ok = Inflight.update(state.client_id, {:received, pubcomp})
    {:noreply, state}
  end

  # SUBSCRIBING ========================================================
  # command ------------------------------------------------------------
  defp handle_package(%Subscribe{}, state) do
    # not a server! (yet)
    {:noreply, state}
  end

  # response -----------------------------------------------------------
  defp handle_package(%Suback{} = suback, state) do
    :ok = Inflight.update(state.client_id, {:received, suback})
    {:noreply, state}
  end

  # UNSUBSCRIBING ======================================================
  # command ------------------------------------------------------------
  defp handle_package(%Unsubscribe{}, state) do
    # not a server
    {:noreply, state}
  end

  # response -----------------------------------------------------------
  defp handle_package(%Unsuback{} = unsuback, state) do
    :ok = Inflight.update(state.client_id, {:received, unsuback})
    {:noreply, state}
  end

  # PING MESSAGES ======================================================
  # command ------------------------------------------------------------
  defp handle_package(%Pingresp{}, %State{ping: ping} = state)
       when is_nil(ping) or ping == {[], []} do
    {:noreply, state}
  end

  defp handle_package(%Pingresp{}, %State{ping: ping} = state) do
    {{:value, {{caller, ref}, start_time}}, ping} = :queue.out(ping)
    round_trip_time = System.monotonic_time(:microsecond) - start_time
    send(caller, {Tortoise, {:ping_response, ref, round_trip_time}})
    {:noreply, %State{state | ping: ping}}
  end

  # response -----------------------------------------------------------
  defp handle_package(%Pingreq{}, state) do
    pingresp = %Package.Pingresp{}
    :ok = Transmitter.cast(state.client_id, pingresp)

    {:noreply, state}
  end

  # CONNECTING =========================================================
  # command ------------------------------------------------------------
  defp handle_package(%Connect{}, state) do
    # not a server!
    {:noreply, state}
  end

  # response -----------------------------------------------------------
  defp handle_package(%Connack{} = _connack, state) do
    # receiving a connack at this point would be a protocol violation
    {:noreply, state}
  end

  # DISCONNECTING ======================================================
  # command ------------------------------------------------------------
  defp handle_package(%Disconnect{}, state) do
    # not a server
    # apply(state.driver, :disconnect, [])
    {:noreply, state}
  end

  # driver callbacks
  defp run_init_callback(state) do
    args = [state.driver.initial_args]

    case apply(state.driver.module, :init, args) do
      {:ok, initial_state} ->
        updated_driver = %{state.driver | state: initial_state}
        {:ok, %__MODULE__{state | driver: updated_driver}}
    end
  end

  defp run_terminate_callback(reason, state) do
    args = [reason, state.driver.state]

    apply(state.driver.module, :terminate, args)
  end

  defp run_publish_callback(%Publish{} = publish, state) do
    topic_list = String.split(publish.topic, "/")
    args = [topic_list, publish.payload, state.driver.state]

    case apply(state.driver.module, :handle_message, args) do
      {:ok, updated_driver_state} ->
        updated_driver = %{state.driver | state: updated_driver_state}
        {:ok, %__MODULE__{state | driver: updated_driver}}
    end
  end

  defp run_subscription_callback(
         %Inflight.Track{type: Package.Subscribe, result: subacks},
         state
       ) do
    # @todo, figure out what to do when a qos is return than the one requested
    updated_driver_state =
      Enum.reduce(subacks, state.driver.state, fn {:ok, {topic_filter, _qos}}, acc ->
        # notice, we ignore the reported qos here for now
        args = [:up, topic_filter, acc]

        case apply(state.driver.module, :subscription, args) do
          {:ok, state} ->
            state
        end
      end)

    updated_driver = %{state.driver | state: updated_driver_state}
    {:ok, %__MODULE__{state | driver: updated_driver}}
  end

  defp run_subscription_callback(
         %Inflight.Track{type: Package.Unsubscribe, result: unsubacks},
         state
       ) do
    updated_driver_state =
      Enum.reduce(unsubacks, state.driver.state, fn topic_filter, acc ->
        args = [:down, topic_filter, acc]

        case apply(state.driver.module, :subscription, args) do
          {:ok, state} ->
            state
        end
      end)

    updated_driver = %{state.driver | state: updated_driver_state}
    {:ok, %__MODULE__{state | driver: updated_driver}}
  end

  defp run_connection_callback(status, state) do
    args = [status, state.driver.state]

    case apply(state.driver.module, :connection, args) do
      {:ok, updated_driver_state} ->
        updated_driver = %{state.driver | state: updated_driver_state}
        {:ok, %State{state | driver: updated_driver}}
    end
  end
end
