defmodule Tortoise.Handler.Logger do
  @moduledoc false

  require Logger

  use Tortoise.Handler

  defstruct []
  alias __MODULE__, as: State

  def init(_opts) do
    Logger.info("Initializing handler")
    {:ok, %State{}}
  end

  def connection(:up, state) do
    Logger.info("Connection has been established")
    {:cont, state}
  end

  def connection(:down, state) do
    Logger.warn("Connection has been dropped")
    {:cont, state}
  end

  def connection(:terminating, state) do
    Logger.warn("Connection is terminating")
    {:cont, state}
  end

  def subscription(:up, topic, state) do
    Logger.info("Subscribed to #{topic}")
    {:ok, state}
  end

  def subscription({:warn, [requested: req, accepted: qos]}, topic, state) do
    Logger.warn("Subscribed to #{topic}; requested #{req} but got accepted with QoS #{qos}")
    {:ok, state}
  end

  def subscription({:error, reason}, topic, state) do
    Logger.error("Error subscribing to #{topic}; #{inspect(reason)}")
    {:ok, state}
  end

  def subscription(:down, topic, state) do
    Logger.info("Unsubscribed from #{topic}")
    {:ok, state}
  end

  def handle_message(topic, publish, state) do
    Logger.info("#{Enum.join(topic, "/")} #{inspect(publish)}")
    {:ok, state}
  end

  @impl true
  def handle_disconnect(disconnect, state) do
    Logger.info("Received disconnect from server #{inspect(disconnect)}")
    {:ok, state}
  end

  def terminate(reason, _state) do
    Logger.warn("Client has been terminated with reason: #{inspect(reason)}")
    :ok
  end
end
