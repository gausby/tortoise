defmodule Tortoise.Connection.Controller do
  @moduledoc false

  alias Tortoise.Package
  alias Tortoise.Connection.Inflight

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

  alias Tortoise.Driver
  alias Tortoise.Connection.Transmitter

  use GenServer

  defstruct client_id: nil, driver: %Driver{}

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

  def via_name(client_id) do
    key = {__MODULE__, client_id}
    {:via, Registry, {Registry.Tortoise, key}}
  end

  def stop(client_id) do
    GenServer.stop(via_name(client_id))
  end

  def handle_incoming(client_id, package) do
    GenServer.cast(via_name(client_id), {:incoming, package})
  end

  # Server callbacks
  def init(%__MODULE__{} = opts) do
    case run_init_callback(opts) do
      {:ok, %__MODULE__{} = initial_state} ->
        {:ok, initial_state}
    end
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

    {:noreply, state}
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
  defp handle_package(%Suback{} = _suback, state) do
    # :ok = Subscription.acknowledge(state.client_id, suback)
    {:noreply, state}
  end

  # UNSUBSCRIBING ======================================================
  # command ------------------------------------------------------------
  defp handle_package(%Unsubscribe{}, state) do
    # not a server
    {:noreply, state}
  end

  # response -----------------------------------------------------------
  defp handle_package(%Unsuback{} = _unsuback, state) do
    # :ok = Subscription.acknowledge(state.client_id, unsuback)
    {:noreply, state}
  end

  # PING MESSAGES ======================================================
  # command ------------------------------------------------------------
  defp handle_package(%Pingresp{}, state) do
    IO.inspect("Pong")
    {:noreply, state}
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
  defp handle_package(%Connack{} = connack, state) do
    IO.inspect(connack)
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

  defp run_publish_callback(%Publish{} = publish, state) do
    topic_list = String.split(publish.topic, "/")
    args = [topic_list, publish.payload, state.driver.state]

    case apply(state.driver.module, :on_publish, args) do
      {:ok, updated_driver_state} ->
        updated_driver = %{state.driver | state: updated_driver_state}
        {:ok, %__MODULE__{state | driver: updated_driver}}
    end
  end
end
