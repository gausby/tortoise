defmodule Tortoise.Driver.Logger do
  @moduledoc false

  require Logger

  defstruct []
  alias __MODULE__, as: State

  @behaviour Tortoise.Driver

  def init(_opts) do
    {:ok, %State{}}
  end

  def connection(:up, state) do
    Logger.info("Connection has been established")
    {:ok, state}
  end

  def connection(:down, state) do
    Logger.warn("Connection has been dropped")
    {:ok, state}
  end

  def subscription(:up, {topic, qos}, state) do
    Logger.info("Subscribed to #{topic} with QoS #{qos}")
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
end
