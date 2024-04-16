defmodule Tortoise311.Handler.Logger do
  @moduledoc false

  use Tortoise311.Handler

  alias __MODULE__, as: State

  require Logger

  defstruct []

  def init(_opts) do
    Logger.info("Initializing handler")
    {:ok, %State{}}
  end

  def connection(:up, state) do
    Logger.info("Connection has been established")
    {:ok, state}
  end

  def connection(:down, state) do
    Logger.warning("Connection has been dropped")
    {:ok, state}
  end

  def connection(:terminating, state) do
    Logger.warning("Connection is terminating")
    {:ok, state}
  end

  def connected(server, socket, state) do
    Logger.warning("Connected via #{inspect(server)} socket #{inspect(socket)}")
    {:ok, state}
  end

  def subscription(:up, topic, state) do
    Logger.info("Subscribed to #{topic}")
    {:ok, state}
  end

  def subscription({:warn, [requested: req, accepted: qos]}, topic, state) do
    Logger.warning("Subscribed to #{topic}; requested #{req} but got accepted with QoS #{qos}")
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

  def terminate(reason, _state) do
    Logger.warning("Client has been terminated with reason: #{inspect(reason)}")
    :ok
  end
end
